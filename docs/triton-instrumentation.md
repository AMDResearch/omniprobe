# Triton Kernel Instrumentation

Instrument Triton-compiled GPU kernels with Omniprobe for runtime memory
analysis. Omniprobe injects LLVM IR passes during Triton's JIT compilation to
produce instrumented kernel variants that report cache line utilization, bank
conflicts, and memory access patterns — without modifying your Triton source.

## Why a custom LLVM build is required

Omniprobe's instrumentation works by injecting LLVM IR passes (shared library
plugins, `.so` files) into the compilation pipeline. These plugins link against
LLVM's C++ API at load time.

Triton JIT-compiles kernels using its own bundled LLVM, which it downloads to
`~/.triton/llvm/`. That bundled LLVM is built with **static** libraries — our
pass plugins cannot `dlopen` alongside a statically-linked LLVM because the
LLVM symbols are not exported.

We need to rebuild LLVM with `-DBUILD_SHARED_LIBS=ON` so that our
instrumentation plugins can link against the same LLVM instance that Triton
uses. The `triton_install.sh` script automates this: it builds LLVM as shared
libraries, then builds Triton against that LLVM.

## Prerequisites

| Requirement | Notes |
|---|---|
| ROCm | Tested with 7.2.0. `ROCM_PATH` must be set. |
| Python >= 3.10 | PyTorch ROCm wheels require 3.10+. |
| AMD GPU | gfx90a, gfx942, etc. |
| Network access | Unless using `--local-sources` (see below). |
| ~50 GB disk space | LLVM build is large. |
| cmake, ninja | Installed via pip if not available. |

## Step 1: Build Triton with shared LLVM

The `triton_install.sh` script handles everything: cloning Triton, building
LLVM with shared libraries, creating a Python venv, installing PyTorch, and
building Triton against the custom LLVM.

```bash
cd ~/repos
ROCM_PATH=/opt/rocm-7.2.0 /path/to/omniprobe/containers/triton_install.sh
```

This runs in the current directory and creates a `triton/` subdirectory
containing the full build. The script takes 15-90 minutes depending on
available cores and network speed.

### Options

| Flag | Description | Default |
|---|---|---|
| `--triton-version TAG` (or `-g TAG`) | Triton version to build (git tag or commit hash) | Latest release from GitHub API |
| `--pytorch-rocm VER` | PyTorch ROCm wheel index version (e.g., `7.1`) | Highest stable index <= installed ROCm |
| `--local-sources DIR` | Use pre-staged local sources instead of network | Fetch from network |

### What it produces

```
triton/                          # Triton repository
├── .venv/                       # Python venv with Triton, PyTorch, dependencies
├── llvm-project/
│   └── build/                   # LLVM build with shared libraries
│       └── lib/libLLVM*.so      # ← these are what make plugins work
└── third_party/amd/backend/
    └── compiler.py              # Patched for instrumentation compatibility
```

The key output paths:
- **Triton venv**: `~/repos/triton/.venv` — activate this before using Triton
- **LLVM build**: `~/repos/triton/llvm-project/build` — pass to Omniprobe's CMake

## Using pre-downloaded sources (`--local-sources`)

Use this when network access is slow, unreliable, or unavailable (air-gapped
environments).

### Prepare the local sources directory

**1. Clone the Triton repository:**

```bash
git clone https://github.com/triton-lang/triton.git ~/repos/sandbox/triton
cd ~/repos/sandbox/triton
git checkout v3.6.0  # or your desired version
```

**2. Clone the LLVM submodule at the correct commit:**

The required LLVM commit hash is in `cmake/llvm-hash.txt`:

```bash
LLVM_HASH=$(cat cmake/llvm-hash.txt)
git clone https://github.com/llvm/llvm-project.git ~/repos/sandbox/triton/llvm-project
cd ~/repos/sandbox/triton/llvm-project
git checkout $LLVM_HASH
```

**3. Download PyTorch and torchvision ROCm wheels:**

```bash
mkdir -p ~/repos/sandbox/triton/wheels
cd ~/repos/sandbox/triton/wheels

# Find the appropriate wheels at https://download.pytorch.org/whl/rocmX.Y/
# Download torch and torchvision for your Python version and ROCm version
pip download torch torchvision \
    --index-url https://download.pytorch.org/whl/rocm7.1 \
    --dest . --no-deps
```

### Run with local sources

```bash
cd ~/repos
ROCM_PATH=/opt/rocm-7.2.0 /path/to/omniprobe/containers/triton_install.sh \
    --local-sources ~/repos/sandbox/triton
```

The script clones from the local repo (no network), uses the pre-populated
`llvm-project/` directory, and installs wheels from the `wheels/` subdirectory.

## Step 2: Build Omniprobe with Triton support

Activate the Triton venv (Omniprobe needs the Python environment for Triton
integration), then build with `-DTRITON_LLVM` pointing to the LLVM build:

```bash
cd /path/to/omniprobe
source ~/repos/triton/.venv/bin/activate

TRITON_DIR=~/repos/triton

cmake -B build \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_HIP_ARCHITECTURES=gfx90a \
    -DTRITON_LLVM=$(realpath $TRITON_DIR/llvm-project/build) \
    -DCMAKE_INSTALL_PREFIX=$(pwd)/install

cmake --build build -j$(nproc)
```

**Important:**

- **`-DTRITON_LLVM` must be an absolute path.** Do not use `~` or shell
  variables that haven't been expanded — CMake passes this value to an
  `ExternalProject` sub-build which does not perform tilde expansion, causing
  the sub-build to fail with "LLVM_INSTALL_DIR is invalid". Use `$(realpath ...)`
  or write out the full path.
- **`-DCMAKE_INSTALL_PREFIX` must be set.** The default (`/`) causes permission
  errors during the install step of the `instrument-amdgpu-kernels` sub-builds.
  Setting it to `$(pwd)/install` or any writable path avoids this.

Setting `-DTRITON_LLVM` tells CMake to build the `-triton` instrumentation
plugins in addition to the standard `-rocm` plugins. Both plugin variants are
built from the same source (`external/instrument-amdgpu-kernels`) but link
against different LLVM installations:

| Plugin | Links against | Used by |
|---|---|---|
| `libAMDGCNSubmitAddressMessages-rocm.so` | ROCm's LLVM (`$ROCM_PATH/llvm`) | rocBLAS, hipBLASLt, hipcc-compiled kernels |
| `libAMDGCNSubmitAddressMessages-triton.so` | Triton's LLVM (`$TRITON_LLVM`) | Triton JIT-compiled kernels |

## Step 3: Run tests

### LD_LIBRARY_PATH

When running from a build tree (without `cmake --install`), the Omniprobe
handler shared libraries (e.g., `libdefaultMessageHandlers64.so`) live in
`build/` but the `omniprobe` script's library search path doesn't include
it automatically. Set `LD_LIBRARY_PATH` to include the build directory:

```bash
export LD_LIBRARY_PATH=/path/to/omniprobe/build:$LD_LIBRARY_PATH
```

This is only needed when running from the build tree. After `cmake --install`,
the libraries are copied to the install prefix and found automatically.

### Handler tests

These test the core Omniprobe runtime (message handlers, analyzers, filters)
using pre-compiled test kernels. They do not require Triton.

```bash
./tests/run_handler_tests.sh
```

Expected: all tests pass (currently 19/19 with ROCm 7.2.0 on gfx90a).

### Triton integration tests

These verify that Omniprobe can instrument Triton-compiled kernels end-to-end:
plugin invocation during JIT, instrumented kernel dispatch, and report
generation.

```bash
export TRITON_DIR=~/repos/triton
./tests/triton/run_test.sh
```

The test suite runs 5 tests:

| Test | Verifies |
|---|---|
| `triton_instrumentation_plugin` | Instrumentation plugin runs during Triton JIT compilation |
| `triton_instrumented_dispatch` | Instrumented kernel alternative is found for `add_kernel` |
| `triton_cache_line_report` | L2 cache line use report is generated |
| `triton_bank_conflicts_report` | Bank conflicts report is generated |
| `triton_scope_no_match` | `--instrumentation-scope` filtering produces 0 instrumented instructions when scope doesn't match |

## Example: Memory analysis on a Triton kernel

This example uses a minimal vector-add kernel (based on Triton's first
tutorial) to demonstrate the instrumentation workflow.

### The kernel

```python
import torch
import triton
import triton.language as tl

DEVICE = triton.runtime.driver.active.get_active_torch_device()

@triton.jit
def add_kernel(
    x_ptr,
    y_ptr,
    output_ptr,
    n_elements,
    BLOCK_SIZE: tl.constexpr,
):
    pid = tl.program_id(axis=0)
    block_start = pid * BLOCK_SIZE
    offsets = block_start + tl.arange(0, BLOCK_SIZE)
    mask = offsets < n_elements
    x = tl.load(x_ptr + offsets, mask=mask)
    y = tl.load(y_ptr + offsets, mask=mask)
    output = x + y
    tl.store(output_ptr + offsets, output, mask=mask)

def add(x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
    output = torch.empty_like(x)
    n_elements = output.numel()
    grid = lambda meta: (triton.cdiv(n_elements, meta["BLOCK_SIZE"]),)
    add_kernel[grid](x, y, output, n_elements, BLOCK_SIZE=1024)
    return output
```

### Run with Omniprobe

```bash
source ~/repos/triton/.venv/bin/activate
export TRITON_HIP_LLD_PATH=${ROCM_PATH}/llvm/bin/ld.lld

omniprobe -a MemoryAnalysis -i -c ~/.triton/cache \
    -- python vector_add.py
```

Flags explained:
- `-a MemoryAnalysis` — use the memory analysis handler (cache lines + bank
  conflicts)
- `-i` — run instrumented kernel variants instead of originals
- `-c ~/.triton/cache` — tell Omniprobe where Triton caches compiled kernels
  (this is where instrumented alternatives are stored)

### Understanding the output

The output has several sections:

**Compile-time (instrumentation plugin log):**
```
Running AMDGCNSubmitAddressMessage on module ...
```
Confirms the instrumentation plugin was invoked during Triton's JIT
compilation. You see this once per kernel compilation (cached on subsequent
runs).

**Dispatch-time:**
```
Found instrumented alternative for add_kernel
```
Omniprobe found and loaded the instrumented variant of `add_kernel` from the
Triton cache.

**L2 cache line use report:**
Shows how efficiently each memory instruction uses L2 cache lines. A
utilization of 100% means every byte in every fetched cache line was used by
the kernel. Lower values indicate spatial locality issues.

**Bank conflicts report:**
Shows LDS (shared memory) bank conflicts per instruction. Zero conflicts is
ideal. Non-zero values indicate address patterns that serialize memory access
across wavefront lanes.

### Filtering with `--instrumentation-scope`

To limit instrumentation to specific source lines (useful for large kernels):

```bash
omniprobe -a MemoryAnalysis -i -c ~/.triton/cache \
    --instrumentation-scope "vector_add.py:21,22,23" \
    -- python vector_add.py
```

This instruments only the `tl.load` and `tl.store` lines, reducing overhead
and focusing the report on the memory operations you care about.

## Reference: Omniprobe CLI options relevant to Triton

| Flag | Description |
|---|---|
| `-a`, `--analyzers` | Analyzer(s) to use. Common values: `MemoryAnalysis`, `AddressLogger`, `Heatmap`. |
| `-i`, `--instrumented` | Run instrumented kernel variants instead of originals. |
| `-c`, `--cache-location` | Path to Triton's kernel cache (typically `~/.triton/cache`). |
| `-k`, `--kernels` | Kernel name filter (ECMAScript regex). Only matching kernels are instrumented. |
| `-d`, `--dispatches` | Which dispatches to capture. Options: `all`, `random`, `1`. |
| `--instrumentation-scope` | Limit instrumentation to specific source locations. Format: `file[:line_spec,...][;file...]`. |
| `--instrumentation-scope-file` | File containing scope definitions (same syntax, one per line). |
| `--filter-x`, `--filter-y`, `--filter-z` | Filter output by block index. Format: `N` (single) or `N:M` (half-open range). |
| `--library-filter` | JSON config for filtering which libraries are scanned. |
| `-l`, `--log-location` | Output destination. Default: `console`. |
| `-t`, `--log-format` | Output format: `csv` or `json`. |
| `-v`, `--verbose` | Verbose output. |

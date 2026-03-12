# Maximal rocBLAS + hipBLASLt Instrumentation

Build rocBLAS and hipBLASLt from the `rocm-libraries` monorepo with omniprobe
instrumentation for comprehensive GPU kernel memory analysis.

## Overview

rocBLAS dispatches GPU kernels through several paths, each with different
instrumentation characteristics:

### rocBLAS kernel types

| Kernel Type | Source | Compilation Path | Instrumentable? |
|------------|--------|------------------|-----------------|
| Non-Tensile (scal, axpy, etc.) | HIP C++ in librocblas.so | hipcc → .hip_fatbin | **Yes** via CMAKE_CXX_FLAGS |
| Tensile GEMM (asm_full default) | Python → Assembly | .s → .o → .co | **No** (bypasses LLVM IR) |
| Tensile GEMM (hip_full) | Python → HIP C++ | hipcc → .hsaco | **Yes** via patched SourceCommands.py |
| Tensile fallback (in asm_full) | Python → HIP C++ | hipcc → .hsaco | **Yes** via patched SourceCommands.py |

### hipBLASLt kernel types

| Kernel Type | Source | Compilation Path | Instrumentable? |
|------------|--------|------------------|-----------------|
| Matrix Transform (96 kernels) | Static HIP C++ | hipcc → .hsaco | **Yes** via -fpass-plugin |
| TensileLite GEMM | Python → Assembly | .s → .o → .co | **No** (assembly-only) |
| TensileLite Helpers (BetaOnly, Conversion, Reduction) | Python → HIP C++ | hipcc → .co | **No** (see [Limitations](#limitations)) |
| Extension Ops (LayerNorm, Softmax, AMax) | Python → Assembly | .s → .o → .co | **No** (assembly) |

The LLVM instrumentation pass (`-fpass-plugin`) operates on LLVM IR. Assembly
kernels bypass IR entirely and cannot be instrumented.

## Why hip_full is required for Tensile

The default rocBLAS build uses `Tensile_LOGIC=asm_full`, which generates
hand-tuned assembly kernels. For instrumentation, `hip_full` is required
because it builds all Tensile kernels as HIP C++ source that goes through
LLVM IR.

| Tensile_LOGIC | Assembly kernels | HIP source kernels | Instrumentable | Performance |
|--|--|--|--|--|
| `asm_full` (default) | ~41,000 optimized | ~87 fallbacks | Only ~87 fallbacks | Full (hand-tuned asm) |
| `hip_full` (required) | 0 | ~324 | All ~324 | Reduced (compiler-generated) |

**Combining asm_full and hip_full is impossible.** Assembly and HIP source
Tensile solutions produce fundamentally different kernel names. At least 6
fields differ in the name encoding:

- ISA: `ISA90a` (assembly) vs `ISA000` (HIP source)
- KernelLanguage: `KLA` (assembly) vs `KLS` (source)
- Math instruction: `MAC` vs `FMA`
- Different workgroup dimensions, tile sizes, and memory model flags

Zero kernel name overlap exists between the two. omniprobe's name-based
matching (`__amd_crk_<OriginalName>Pv`) cannot bridge between assembly and
HIP source kernel names.

### hipBLASLt has no build-mode choice

Unlike rocBLAS/Tensile, hipBLASLt does not have a `hip_full` vs `asm_full`
choice. All four kernel types are always built together. The `OMNIPROBE_INSTRUMENT_PLUGIN`
environment variable injects `-fpass-plugin` into the HIP source compilations
(matrix transform), while assembly compilations (GEMM, ExtOps) are unaffected
since they bypass LLVM IR entirely.

## Prerequisites

- ROCm installed (provides `amdclang++`, `clang-offload-bundler`)
- omniprobe built with the `AMDGCNSubmitAddressMessages` plugin
- Python 3.9+ with `pyyaml`, `joblib`, `msgpack` packages
- [msgpack-cxx](https://github.com/msgpack/msgpack-c) header-only library
  (required by TensileLite host library; install from the `cpp-7.0.0` tag)
- ~20 GB disk space for builds
- GPU access (e.g., gfx90a)

Set `ROCM_PATH` to your ROCm installation before starting (all commands below
use this variable):

```bash
ROCM_PATH=/opt/rocm-7.2.0   # adjust to your installed version
```

### Install msgpack-cxx (if not already available)

TensileLite's host library requires the msgpack-cxx headers. If not available
on your system:

```bash
git clone --depth 1 --branch cpp-7.0.0 https://github.com/msgpack/msgpack-c.git /tmp/msgpack-c
cmake -B /tmp/msgpack-build -S /tmp/msgpack-c \
    -DMSGPACK_CXX20=ON -DMSGPACK_BUILD_TESTS=OFF -DMSGPACK_BUILD_EXAMPLES=OFF \
    -DCMAKE_INSTALL_PREFIX=$HOME/.local
cmake --install /tmp/msgpack-build
rm -rf /tmp/msgpack-c /tmp/msgpack-build
```

Then add `$HOME/.local` to `CMAKE_PREFIX_PATH` in the build commands below.

## Step 1: Clone rocm-libraries (sparse checkout)

The standalone `ROCm/hipBLASLt` and `ROCm/rocBLAS` repos are deprecated. Use
the `rocm-libraries` monorepo:

```bash
SANDBOX=/path/to/build/directory
cd $SANDBOX

git clone --no-checkout --filter=blob:none https://github.com/ROCm/rocm-libraries.git
cd rocm-libraries
git sparse-checkout init --cone
git sparse-checkout set \
    projects/hipblaslt projects/rocblas projects/hipblas-common \
    shared/rocroller shared/mxdatagenerator shared/origami shared/tensile \
    cmake
git checkout rocm-$(rocminfo 2>/dev/null | grep -oP 'ROCm Runtime Version: \K[0-9]+\.[0-9]+\.[0-9]+' || echo "VERSION")
# e.g., git checkout rocm-7.2.0
```

## Step 2: Build hipBLASLt with instrumentation

hipBLASLt's matrix transform kernels are compiled from HIP C++ source. We
inject the instrumentation plugin via the `OMNIPROBE_INSTRUMENT_PLUGIN`
environment variable, which is checked by a patched `matrix-transform/CMakeLists.txt`.

**Important:** Build hipBLASLt completely from source, including the host
library (`libhipblaslt.so`). Do not symlink or copy the system hipBLASLt
library — the host library uses `dladdr()` to find its own directory at
runtime, and symlinks resolve to the system path, causing it to load system
device code objects instead of instrumented ones.

### 2a: Patch the build

Apply the following patch to inject `-fpass-plugin` into the matrix transform
compilation:

**`projects/hipblaslt/device-library/matrix-transform/CMakeLists.txt`** — add
before the `add_custom_command`:

```cmake
# Omniprobe instrumentation: inject -fpass-plugin if OMNIPROBE_INSTRUMENT_PLUGIN is set
set(instrument_flags "")
if(DEFINED ENV{OMNIPROBE_INSTRUMENT_PLUGIN})
    set(instrument_flags "-fpass-plugin=$ENV{OMNIPROBE_INSTRUMENT_PLUGIN}")
    message(STATUS "matrix_transform: instrumenting with ${instrument_flags}")
endif()
```

Then add `${instrument_flags}` to the `add_custom_command` COMMAND:

```cmake
add_custom_command(
    COMMAND ${CMAKE_CXX_COMPILER} ${instrument_flags} -x hip ${matrix_transform_cpp} ...
```

### 2b: Configure and build

The `OMNIPROBE_INSTRUMENT_PLUGIN` environment variable must be **exported**
(not just set as a command prefix) because CMake's `$ENV{}` reads from the
process environment:

```bash
PLUGIN=/path/to/omniprobe/build/external/instrument-amdgpu-kernels-rocm/build/lib/libAMDGCNSubmitAddressMessages-rocm.so

export OMNIPROBE_INSTRUMENT_PLUGIN=$PLUGIN

cmake \
    -B $SANDBOX/hipblaslt-build \
    -S $SANDBOX/rocm-libraries/projects/hipblaslt \
    -DHIPBLASLT_ENABLE_DEVICE=ON \
    -DHIPBLASLT_ENABLE_HOST=ON \
    -DTENSILELITE_ENABLE_HOST=ON \
    -DHIPBLASLT_ENABLE_CLIENT=OFF \
    -DHIPBLASLT_ENABLE_MSGPACK=ON \
    -DHIPBLASLT_ENABLE_ROCROLLER=OFF \
    -DHIPBLASLT_ENABLE_LAZY_LOAD=ON \
    -DGPU_TARGETS=gfx90a \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_COMPILER=$ROCM_PATH/bin/amdclang++ \
    -DCMAKE_C_COMPILER=$ROCM_PATH/bin/amdclang \
    -DCMAKE_ASM_COMPILER=$ROCM_PATH/bin/amdclang++ \
    -DCMAKE_PREFIX_PATH="$ROCM_PATH;$HOME/.local" \
    -DCMAKE_INSTALL_PREFIX=$SANDBOX/hipblaslt-install \
    -DTENSILELITE_BUILD_PARALLEL_LEVEL=8

cmake --build $SANDBOX/hipblaslt-build -- -j8
cmake --install $SANDBOX/hipblaslt-build
```

Key configuration notes:
- `HIPBLASLT_ENABLE_HOST=ON` and `TENSILELITE_ENABLE_HOST=ON`: Build the
  complete host library from source. Do not use the system `libhipblaslt.so`.
- `HIPBLASLT_ENABLE_MSGPACK=ON`: Required for TensileLite host library
  (`MessagePackLoadLibraryMapping`).
- `HIPBLASLT_ENABLE_ROCROLLER=OFF`: RocRoller is only needed for ExtOps
  regeneration, not for matrix transform instrumentation.
- `CMAKE_ASM_COMPILER`: Must be set to `amdclang++` for ExtOps assembly.
- `CMAKE_PREFIX_PATH`: Include `$HOME/.local` (or wherever msgpack-cxx was
  installed) so CMake can find it.
- The install goes to `lib64/` on most Linux systems (not `lib/`).

### 2c: Unbundle and verify

The matrix transform hsaco is a Clang Offload Bundle. Unbundle it for the
omniprobe library filter:

```bash
HIPBLASLT_INSTALL=$SANDBOX/hipblaslt-install
# Note: install uses lib64/ on most Linux systems
HIPBLASLT_LIB_DIR=$HIPBLASLT_INSTALL/lib64

$ROCM_PATH/llvm/bin/clang-offload-bundler \
    --unbundle --type=o \
    --targets=hipv4-amdgcn-amd-amdhsa--gfx90a \
    --input=$HIPBLASLT_LIB_DIR/hipblaslt/library/hipblasltTransform.hsaco \
    --output=$HIPBLASLT_LIB_DIR/hipblaslt/library/hipblasltTransform-gfx90a.hsaco

# Verify instrumented symbols
nm $HIPBLASLT_LIB_DIR/hipblaslt/library/hipblasltTransform-gfx90a.hsaco | grep __amd_crk_ | wc -l
# Expected: ~960 instrumented symbols
```

## Step 3: Build rocBLAS with instrumentation

### 3a: Configure

```bash
cmake \
    -B $SANDBOX/rocblas-build \
    -S $SANDBOX/rocm-libraries/projects/rocblas \
    -DCMAKE_TOOLCHAIN_FILE=$SANDBOX/rocm-libraries/projects/rocblas/toolchain-linux.cmake \
    -DROCM_PATH=$ROCM_PATH \
    -DCMAKE_INSTALL_PREFIX=$SANDBOX/rocblas-install \
    -DCMAKE_PREFIX_PATH="$ROCM_PATH;$HIPBLASLT_INSTALL" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGPU_TARGETS="gfx90a" \
    -DTensile_LOGIC=hip_full \
    -DTensile_LAZY_LIBRARY_LOADING=OFF \
    -DTensile_SEPARATE_ARCHITECTURES=ON \
    -DTensile_LIBRARY_FORMAT=yaml \
    -DBUILD_WITH_HIPBLASLT=ON \
    -Dhipblaslt_path=$HIPBLASLT_INSTALL \
    -DBUILD_OFFLOAD_COMPRESS=ON \
    -DBUILD_CLIENTS_TESTS=OFF \
    -DBUILD_CLIENTS_BENCHMARKS=OFF \
    -DBUILD_CLIENTS_SAMPLES=OFF \
    -DCMAKE_CXX_FLAGS="-fpass-plugin=$PLUGIN -ggdb"
```

### 3b: Patch Tensile SourceCommands.py

Tensile's kernel compilation uses hardcoded flags that do not include the
instrumentation plugin. After CMake configure (which installs Tensile into a
virtualenv), patch `SourceCommands.py`:

```bash
VENV_PATH=$(find $SANDBOX/rocblas-build/virtualenv -name "SourceCommands.py" -path "*/BuildCommands/*")

sed -i 's/\["--cuda-device-only", "-x", "hip", "-O3"\]/["--cuda-device-only", "-x", "hip", "-O3", "-g", "-fpass-plugin=\/path\/to\/plugin.so"]/' "$VENV_PATH"

# Verify
grep "fpass-plugin" "$VENV_PATH"
```

### 3c: Build and install

```bash
cmake --build $SANDBOX/rocblas-build -- -j$(nproc)
cmake --install $SANDBOX/rocblas-build
```

### 3d: Verify

```bash
# Non-Tensile kernels instrumented in librocblas.so
nm $SANDBOX/rocblas-install/lib/librocblas.so | grep __amd_crk_ | head

# Tensile kernels instrumented in .hsaco files
nm $SANDBOX/rocblas-install/lib/rocblas/library/Kernels.so-000-gfx90a*.hsaco | grep __amd_crk_ | head
```

## Step 4: Run with omniprobe

### Filesystem requirement

ROCm 7.2+ uses `mmap()` to load code objects via `hipModuleLoad()`. This
requires the install directory to be on a filesystem that supports `mmap` —
such as ext4, XFS, or tmpfs. **Virtual filesystems like virtiofs do not support
`mmap` and will cause `hipModuleLoad` to fail with `hipErrorInvalidValue`.**

If your build directory is on virtiofs or another virtual filesystem, copy the
install directories to a local filesystem before running:

```bash
cp -a $SANDBOX/hipblaslt-install /tmp/hipblaslt-install
cp -a $SANDBOX/rocblas-install /tmp/rocblas-install
```

### rocBLAS only

```bash
LD_LIBRARY_PATH=$SANDBOX/rocblas-install/lib:$LD_LIBRARY_PATH \
omniprobe -i -a MemoryAnalysis -- /path/to/your-rocblas-application
```

### rocBLAS + hipBLASLt transform kernels

For hipBLASLt kernels loaded via `hipModuleLoad()`, use `--library-filter` to
tell omniprobe where to find the instrumented code objects:

```bash
# Create library filter config
cat > /tmp/hipblaslt_filter.json << 'EOF'
{
    "include": [
        "/path/to/hipblaslt-install/lib64/hipblaslt/library/hipblasltTransform-gfx90a.hsaco"
    ]
}
EOF

LD_LIBRARY_PATH=$SANDBOX/rocblas-install/lib:$SANDBOX/hipblaslt-install/lib64:$LD_LIBRARY_PATH \
omniprobe -i -a MemoryAnalysis \
    --library-filter /tmp/hipblaslt_filter.json \
    -- /path/to/your-application
```

Note: On gfx90a, rocBLAS defaults to Tensile for GEMM. Set
`ROCBLAS_USE_HIPBLASLT=1` to force the hipBLASLt backend. The matrix transform
kernels are dispatched when data format conversion is needed (e.g., between
row-major and column-major layouts, or between data types).

## Limitations

1. **TensileLite GEMM kernels (hipBLASLt)** are assembly-only. TensileLite has
   no `hip_full` equivalent. There is a hard assertion in TensileLite:
   "Only assembly kernels are supported in TensileLite".

2. **TensileLite helper kernels** (BetaOnly, Conversion, Reduction) are
   generated as HIP C++ but compiled as a single 564K-line `Kernels.cpp` file.
   The instrumentation plugin crashes (LLVM ICE) on this massive file. These
   kernels are instrumentable in theory but not in practice with the current
   plugin.

3. **Extension operations** (LayerNorm, Softmax, AMax) are generated as
   assembly and cannot be instrumented.

4. **Matrix transform kernels are not always dispatched.** They are used for
   data layout or type conversions. A GEMM operation that doesn't require
   format conversion may not trigger any matrix transform kernels.

5. **hip_full trades performance for coverage.** The compiler-generated HIP
   source kernels have fewer variants (~324 vs ~41,000) and potentially
   different performance than hand-tuned assembly. For profiling/analysis
   purposes, this is the correct choice.

6. **Virtual filesystems (virtiofs) are not supported.** ROCm 7.2+ uses
   `mmap()` to load code objects. If the install directory is on virtiofs,
   `hipModuleLoad()` will fail with `hipErrorInvalidValue`. Copy the install
   to a local filesystem (ext4, XFS, tmpfs) before running.

## Environment Variables Reference

| Variable | Purpose |
|---|---|
| `OMNIPROBE_INSTRUMENT_PLUGIN` | Path to the instrumentation plugin .so file (must be `export`ed) |
| `ROCBLAS_USE_HIPBLASLT` | `0` to disable hipBLASLt, `1` to force it |
| `HIPBLASLT_TENSILE_LIBPATH` | Override path to TensileLite kernel library |
| `HIPBLASLT_EXT_OP_LIBRARY_PATH` | Override path to extension operations library |
| `HIPBLASLT_LOG_LEVEL` | Set to `info` for debug logging |
| `Tensile_CXX_COMPILER_LAUNCHER` | Compiler launcher for Tensile builds |
| `ROCR_VISIBLE_DEVICES` | GPU device selection for testing |

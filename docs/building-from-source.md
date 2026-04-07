# Building from Source

## Prerequisites

| Requirement | Minimum Version | Notes |
|-------------|----------------|-------|
| ROCm | 7.0 | Tested with 7.0, 7.1, 7.2 |
| CMake | 3.15 | |
| C++20 compiler | hipcc (ships with ROCm) | |
| Python | 3.10+ | Required for the `omniprobe` CLI and Triton support |

### System packages

On Ubuntu 24.04 (the reference platform), install:

```bash
sudo apt-get install -y git build-essential cmake ninja-build clang lld \
    libzstd-dev libomp-dev libdwarf-dev python3-dev python3-venv
```

ROCm must be installed separately — see the
[ROCm installation guide](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/).
In addition to the base ROCm packages, you need the LLVM development headers:

```bash
sudo apt-get install -y rocm-llvm-dev
```

## Supported GPU architectures

Omniprobe builds instrumentation for the following AMD GPU targets:

| Architecture | Examples |
|-------------|----------|
| gfx900 | Vega 10 |
| gfx906 | Radeon VII, MI50 |
| gfx908 | MI100 |
| gfx90a | MI210, MI250, MI250X |
| gfx942 | MI300A, MI300X |
| gfx1030–gfx1032 | RDNA 2 |
| gfx1100–gfx1102 | RDNA 3 |

You only need to build for the architecture(s) you intend to run on.
Use `-DCMAKE_HIP_ARCHITECTURES=<arch>` to select specific targets.

## Clone

```bash
git clone --recurse-submodules https://github.com/AMDResearch/omniprobe.git
cd omniprobe
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

## Configure and build

```bash
cmake -B build \
    -DROCM_PATH=/opt/rocm \
    -DCMAKE_HIP_ARCHITECTURES=gfx90a \
    -DCMAKE_INSTALL_PREFIX=$PWD/install \
    -DINTERCEPTOR_BUILD_TESTING=ON

cmake --build build -j$(nproc)
```

### CMake options

| Option | Default | Description |
|--------|---------|-------------|
| `ROCM_PATH` | `/opt/rocm` | ROCm installation path |
| `CMAKE_HIP_ARCHITECTURES` | all supported | GPU architectures to build for |
| `CMAKE_INSTALL_PREFIX` | — | Installation destination (required) |
| `INTERCEPTOR_BUILD_TESTING` | `OFF` | Build test kernels and enable `ctest` |
| `TRITON_LLVM` | — | Path to a shared-library LLVM build for Triton plugin support (see below) |

## Install

```bash
cmake --install build
```

This installs to the directory specified by `CMAKE_INSTALL_PREFIX`. The layout is:

```
<prefix>/omniprobe/
    bin/omniprobe          # CLI script
    config/                # Python config modules
    lib/*.so               # Interceptor and handler libraries
    lib/plugins/*.so       # LLVM instrumentation plugins
    lib/bitcode/*.bc       # Device bitcode
```

## Running tests

Tests require a GPU of the architecture you built for. Enable tests at configure
time with `-DINTERCEPTOR_BUILD_TESTING=ON`, then:

```bash
# From the build tree (add build dir to library path):
LD_LIBRARY_PATH=$PWD/build:$LD_LIBRARY_PATH tests/run_handler_tests.sh

# From the install tree:
OMNIPROBE_ROOT=$PWD/install/omniprobe tests/run_handler_tests.sh
```

The main test suites are:

| Script | Description |
|--------|-------------|
| `tests/run_handler_tests.sh` | Full handler test suite |
| `tests/run_basic_tests.sh` | Basic heatmap and memory analysis tests |
| `tests/run_block_filter_tests.sh` | Block index filtering tests |
| `tests/run_library_filter_tests.sh` | Library filter chain tests |
| `tests/run_module_load_tests.sh` | Runtime module-load kernel discovery tests |
| `tests/run_scope_filter_tests.sh` | Instrumentation scope filtering tests |
| `tests/run_all_tests.sh` | Runs all of the above |

## Building with Triton support

To instrument Triton kernels, Omniprobe needs a shared-library build of LLVM
that matches the version Triton was built against. The `containers/triton_install.sh`
script automates this:

```bash
# Install Triton with shared-library LLVM
./containers/triton_install.sh --triton-version v3.6.0

# Point Omniprobe's build at the resulting LLVM
cmake -B build \
    -DROCM_PATH=/opt/rocm \
    -DCMAKE_HIP_ARCHITECTURES=gfx90a \
    -DCMAKE_INSTALL_PREFIX=$PWD/install \
    -DTRITON_LLVM=/path/to/triton/llvm-project/build \
    -DINTERCEPTOR_BUILD_TESTING=ON
```

> **Note**: The `TRITON_LLVM` path must be absolute — `~` is not expanded in
> sub-builds.

For detailed Triton usage, see [Triton Instrumentation](triton-instrumentation.md).

## Troubleshooting

### `hipModuleLoad` fails at runtime

Instrumented libraries (`.hsaco` files) must reside on a filesystem that supports
`mmap`. Some virtual filesystems (e.g., virtiofs) do not. Copy instrumented
libraries to a local filesystem like `/tmp` before loading.

### Libraries not found at runtime

When running from the build tree (before `cmake --install`), shared libraries are
in `build/`. Add it to your library path:

```bash
export LD_LIBRARY_PATH=$PWD/build:$LD_LIBRARY_PATH
```

### CMake can't find ROCm

Set `ROCM_PATH` explicitly if ROCm is not installed at `/opt/rocm`:

```bash
cmake -B build -DROCM_PATH=/opt/rocm-7.2.0 ...
```

### Permission error during install

If `CMAKE_INSTALL_PREFIX` is not set, CMake defaults to `/`, which requires
root. Always set an explicit install prefix:

```bash
cmake -B build -DCMAKE_INSTALL_PREFIX=$PWD/install ...
```

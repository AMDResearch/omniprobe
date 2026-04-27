# Build System

## Responsibility

CMake-based build system for omniprobe. Handles multi-LLVM-variant plugin
compilation (ROCm and Triton), install tree layout, environment variable
configuration, and external dependency management (submodules, ROCm, LLVM).

## Key Source Files

| File | Purpose |
|------|---------|
| `CMakeLists.txt` | Top-level build configuration |
| `src/CMakeLists.txt` | Interceptor library build |
| `plugins/CMakeLists.txt` | Handler plugin builds |
| `tests/CMakeLists.txt` | Test kernel compilation |
| `tests/test_kernels/CMakeLists.txt` | Test kernel targets with `-g` and `-fpass-plugin` |
| `cmake_modules/add_instrumentation_plugins.cmake` | CMake function for building instrumentation plugins per LLVM variant |
| `src/instrumentation/CMakeLists.txt` | Instrumentation plugin builds |

## Key Types and Classes

N/A — CMake infrastructure, no C++ types.

## Key Functions and Entry Points

| Function | Location | Purpose |
|----------|----------|---------|
| `add_instrumentation_plugins()` | `cmake_modules/add_instrumentation_plugins.cmake` | Called once per LLVM variant (ROCm, Triton) to build instrumentation plugins |

## Data Flow

### Multi-LLVM-Variant Build

Instrumentation plugins must match the LLVM they will be loaded into. The build system
compiles each plugin twice:

- **ROCm variant:** `add_instrumentation_plugins(SUFFIX rocm LLVM_DIR ${ROCM_PATH}/llvm)`
- **Triton variant:** `add_instrumentation_plugins(SUFFIX triton LLVM_DIR ${TRITON_LLVM} LINK_LLVM_LIBS)`

Plugins are compiled using the variant's own `clang++` (from `llvm-config --bindir`),
NOT `hipcc`.

### Build Tree Layout

```
build/
├── lib/
│   └── liblogDuration64.so          # Main tool library
├── plugins/
│   └── lib*.so                      # Handler plugin shared libraries
└── src/instrumentation/
    └── lib*.so                      # LLVM IR instrumentation plugins
```

### Install Tree Layout

```
<prefix>/
├── lib/
│   └── liblogDuration64.so
├── lib/omniprobe/plugins/
│   └── lib*.so
├── lib/omniprobe/instrumentation/
│   └── lib*.so
└── bin/
    └── omniprobe                    # Python orchestrator
```

### Bitcode Location

Bitcode is located via `getBitcodePath()`: looks in `../bitcode/` relative to the plugin
directory.

### Standard Build Command

```bash
cmake -B build -DROCM_PATH=/opt/rocm-7.2.0 -DCMAKE_HIP_ARCHITECTURES=gfx90a \
  -DTRITON_LLVM=/home1/rvanoo/repos/triton/llvm-project/build \
  -DINTERCEPTOR_BUILD_TESTING=ON \
  -DCMAKE_INSTALL_PREFIX=$PWD/install
cmake --build build
cmake --install build
```

## Environment Variables

### Build-time Variables

| Variable | Purpose |
|----------|---------|
| `ROCM_PATH` | ROCm installation prefix (e.g., `/opt/rocm-7.2.0`) |
| `CMAKE_HIP_ARCHITECTURES` | Target GPU architecture (e.g., `gfx90a`) |
| `TRITON_LLVM` | Triton's LLVM build directory (must be absolute path) |
| `INTERCEPTOR_BUILD_TESTING` | Enable GoogleTest integration (OFF by default) |
| `CMAKE_INSTALL_PREFIX` | Install prefix (must be set — default `/` causes permission error) |

### Runtime Variables

| Variable | Purpose |
|----------|---------|
| `LD_PRELOAD` | Set to `liblogDuration64.so` to load the rocprofiler-sdk tool |
| `LOGDUR_HANDLERS` | Comma-separated list of handler shared libraries to load |
| `LOGDUR_LOG_FORMAT` | Output format: `console` (default), `csv`, or `json` |
| `LOGDUR_LIBRARY_FILTER` | Colon-separated list of libraries to include for scanning |
| `LOGDUR_LIBRARY_FILTER_EXCLUDE` | Colon-separated list of libraries to exclude from scanning |
| `LLVM_PASS_PLUGIN_PATH` | Triton mode: path to instrumentation plugin for JIT compilation |
| `INSTRUMENTATION_SCOPE` | Restrict instrumentation to specific source file/lines |
| `INSTRUMENTATION_SCOPE_FILE` | File containing instrumentation scope specification |

## Invariants

- `TRITON_LLVM` must be an absolute path — `~` is not expanded in ExternalProject sub-builds.
- `CMAKE_INSTALL_PREFIX` must be set explicitly — the default causes permission errors.
- `LD_LIBRARY_PATH` must include `build/` when running tests from a clean build (`.so` files
  not in install tree until `cmake --install`).
- Submodules (`dh_comms`, `kerneldb`) must be initialized before building.
- ROCm, HSA runtime, and rocprofiler-sdk are required dependencies.

## Dependencies

- `architecture` — system overview and data flow context
- `instrumentation` — plugins built by this system
- `testing` — test kernels compiled by this system

## Negative Knowledge

- **Do NOT use `hipcc` for instrumentation plugins.** They must be compiled with the LLVM
  variant's own `clang++` to match the LLVM they will be loaded into.
- **GoogleTest is disabled by default** (`INTERCEPTOR_BUILD_TESTING=OFF`). Do not enable
  without handler refactoring for dependency injection.

## Open Questions

None.

## Last Verified

2026-04-27 (created by pm-restructure from architecture + instrumentation)

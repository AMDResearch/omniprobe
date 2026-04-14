# Instrumenting HIP Applications

This guide explains how to instrument your own HIP kernels with Omniprobe.
The process has two phases: **compile time** (add instrumentation to your
kernels) and **runtime** (run the instrumented binary with Omniprobe).

For instrumenting pre-compiled GPU libraries (rocBLAS, hipBLASLt), see
[rocBLAS Maximal Instrumentation](rocblas-maximal-instrumentation.md).
For Triton kernels, see [Triton Instrumentation](triton-instrumentation.md).
For the branch architecture and implementation plan for binary-only `.hsaco`
instrumentation and the converged hidden-argument ABI, see
[HSACO Instrumentation Architecture](hsaco-instrumentation-architecture.md).

## How it works

Omniprobe uses LLVM plugins that run during compilation. When you compile a
HIP source file with a plugin loaded, the plugin:

1. **Clones** each kernel, creating an instrumented variant alongside the
   original
2. **Injects** data-streaming calls into the clone (e.g., memory address
   messages, basic block timestamps)
3. **Adds** an extra `void*` parameter to the clone for the device-host
   communication descriptor

The resulting binary contains both original and instrumented kernels. At
runtime, Omniprobe transparently swaps in the instrumented versions when
analysis is enabled (`-i`).

No source code changes are required.

## Instrumentation plugins

Three plugins are available, each with a `-rocm` variant for HIP:

| Plugin | What it instruments | Used by |
|--------|-------------------|---------|
| `libAMDGCNSubmitAddressMessages-rocm.so` | Global and LDS memory accesses | MemoryAnalysis, Heatmap, AddressLogger |
| `libAMDGCNSubmitBBStart-rocm.so` | Basic block entry timestamps | BasicBlockAnalysis, BasicBlockLogger |
| `libAMDGCNSubmitBBInterval-rocm.so` | Basic block start/stop timing intervals | — |

The address messages plugin is the most commonly used — it enables all
memory-related analyses.

### Plugin locations

| Tree | Path |
|------|------|
| Build | `build/lib/plugins/<plugin>.so` |
| Install | `<prefix>/omniprobe/lib/plugins/<plugin>.so` |

## Compiling with instrumentation

### Compiler flags

```bash
hipcc \
    -fpass-plugin=/path/to/omniprobe/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so \
    -fgpu-rdc \
    --offload-arch=gfx90a \
    -o my_app \
    my_app.cpp
```

| Flag | Purpose |
|------|---------|
| `-fpass-plugin=<path>` | Load the Omniprobe LLVM instrumentation plugin |
| `-fgpu-rdc` | Enable relocatable device code (required for kernel cloning) |
| `--offload-arch=<arch>` | Target GPU architecture |

Both compile and link steps need `-fgpu-rdc`:

```bash
# Separate compilation
hipcc -fgpu-rdc -fpass-plugin=<plugin> -c kernel.cpp -o kernel.o
hipcc -fgpu-rdc kernel.o -o my_app
```

### Complete example

Given a simple HIP application (`my_app.cpp`):

```cpp
#include <hip/hip_runtime.h>
#include <iostream>

__global__ void vector_add(float* a, float* b, float* c, size_t n) {
    size_t i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        c[i] = a[i] + b[i];
    }
}

int main() {
    constexpr size_t N = 1024;
    float *a, *b, *c;
    hipMalloc(&a, N * sizeof(float));
    hipMalloc(&b, N * sizeof(float));
    hipMalloc(&c, N * sizeof(float));

    vector_add<<<N / 256, 256>>>(a, b, c, N);
    hipDeviceSynchronize();

    hipFree(a); hipFree(b); hipFree(c);
    return 0;
}
```

Compile with instrumentation:

```bash
OMNIPROBE=/path/to/omniprobe/build   # or install prefix

hipcc -fgpu-rdc \
    -fpass-plugin=${OMNIPROBE}/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so \
    --offload-arch=gfx90a \
    -o my_app my_app.cpp
```

Run with Omniprobe:

```bash
omniprobe -i -a MemoryAnalysis -- ./my_app
```

## Scoped instrumentation

By default, the plugin instruments all memory accesses (or basic blocks) in
every kernel in the translation unit. You can restrict instrumentation to
specific source files and line ranges using environment variables set at
**compile time**.

### `INSTRUMENTATION_SCOPE`

Format: `file[:line_spec,...][;file[:line_spec,...]]`

Line specs can be a single line `N` or a range `N:M`.

```bash
# Only instrument lines 10-20 of kernel.cpp
INSTRUMENTATION_SCOPE="kernel.cpp:10:20" \
    hipcc -fgpu-rdc -fpass-plugin=<plugin> -o my_app my_app.cpp

# Multiple files and ranges
INSTRUMENTATION_SCOPE="kernel.cpp:10:20,30;utils.cpp:45" \
    hipcc -fgpu-rdc -fpass-plugin=<plugin> -o my_app my_app.cpp
```

### `INSTRUMENTATION_SCOPE_FILE`

Point to a file containing scope definitions, one per line. Blank lines and
lines starting with `#` are ignored.

```bash
# scope.txt:
# Only instrument the hot loop in matmul
matmul.cpp:42,50:60

# And the memory copy kernel
memcpy_kernel.cpp
```

```bash
INSTRUMENTATION_SCOPE_FILE=scope.txt \
    hipcc -fgpu-rdc -fpass-plugin=<plugin> -o my_app my_app.cpp
```

Scoped instrumentation reduces overhead by limiting how much code gets
instrumented. It is especially useful when you already know which kernel or
code region you want to analyze.

> **Note**: For Triton kernels, the `omniprobe` CLI sets these variables
> automatically via `--instrumentation-scope`. For HIP, you set them manually
> before compilation because HIP kernels are compiled ahead of time.

## CMake integration

To add instrumentation to an existing CMake project:

```cmake
# Path to the Omniprobe plugin
set(OMNIPROBE_PLUGIN "/path/to/omniprobe/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so")

add_executable(my_app my_app.cpp)
set_source_files_properties(my_app.cpp PROPERTIES LANGUAGE HIP)

target_compile_options(my_app PRIVATE
    -fgpu-rdc
    -fpass-plugin=${OMNIPROBE_PLUGIN}
)
target_link_options(my_app PRIVATE -fgpu-rdc)
```

To make the plugin path configurable:

```cmake
set(OMNIPROBE_PLUGIN "" CACHE FILEPATH "Path to Omniprobe LLVM instrumentation plugin")

if(OMNIPROBE_PLUGIN)
    target_compile_options(my_app PRIVATE -fpass-plugin=${OMNIPROBE_PLUGIN})
endif()
```

Then configure with:

```bash
cmake -B build -DOMNIPROBE_PLUGIN=/path/to/libAMDGCNSubmitAddressMessages-rocm.so
```

## Choosing a plugin

Which plugin to use depends on what you want to analyze:

**Memory access analysis** — use `libAMDGCNSubmitAddressMessages-rocm.so`:

```bash
# Compile
hipcc -fgpu-rdc -fpass-plugin=.../libAMDGCNSubmitAddressMessages-rocm.so -o my_app my_app.cpp

# Analyze cache line efficiency
omniprobe -i -a MemoryAnalysis -- ./my_app

# Or generate a memory heatmap
omniprobe -i -a Heatmap -- ./my_app

# Or log raw address traces
omniprobe -i -a AddressLogger -t csv -l addresses.csv -- ./my_app
```

**Basic block timing** — use `libAMDGCNSubmitBBStart-rocm.so`:

```bash
# Compile
hipcc -fgpu-rdc -fpass-plugin=.../libAMDGCNSubmitBBStart-rocm.so -o my_app my_app.cpp

# Analyze basic block execution times
omniprobe -i -a BasicBlockAnalysis -- ./my_app

# Or log raw timestamps
omniprobe -i -a BasicBlockLogger -- ./my_app
```

You can only use one plugin per compilation. If you need both memory and basic
block analysis, compile the application twice with different plugins.

## Standalone `.hsaco` compilation

For kernels loaded dynamically via `hipModuleLoad`, compile to a standalone
code object:

```bash
hipcc -x hip \
    --offload-device-only \
    --no-gpu-bundle-output \
    --offload-arch=gfx90a \
    -fpass-plugin=.../libAMDGCNSubmitAddressMessages-rocm.so \
    -o my_kernel.hsaco \
    my_kernel.hip
```

The `.hsaco` file will contain both original and instrumented kernel variants.
Omniprobe auto-discovers the instrumented variants when the code object is
loaded at runtime.

> **Note**: The `.hsaco` file must reside on a filesystem that supports `mmap`.
> See [Building from Source — Troubleshooting](building-from-source.md#hipmoduleload-fails-at-runtime).

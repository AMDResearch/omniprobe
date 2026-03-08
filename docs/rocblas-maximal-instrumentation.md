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

- ROCm 7.1.0 installed (provides `amdclang++`, `clang-offload-bundler`)
- omniprobe built with the `AMDGCNSubmitAddressMessages` plugin
- Python 3.9+ with `pyyaml`, `joblib`, `msgpack` packages
- ~20 GB disk space for builds
- GPU access (e.g., gfx90a)

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
git checkout rocm-7.1.0
```

## Step 2: Build hipBLASLt with instrumentation

hipBLASLt's matrix transform kernels are compiled from HIP C++ source. We
inject the instrumentation plugin via the `OMNIPROBE_INSTRUMENT_PLUGIN`
environment variable, which is checked by a patched `matrix-transform/CMakeLists.txt`.

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

```bash
PLUGIN=/path/to/omniprobe/build/external/instrument-amdgpu-kernels-rocm/build/lib/libAMDGCNSubmitAddressMessages-rocm.so

OMNIPROBE_INSTRUMENT_PLUGIN=$PLUGIN \
cmake \
    -B $SANDBOX/hipblaslt-build \
    -S $SANDBOX/rocm-libraries/projects/hipblaslt \
    -DHIPBLASLT_ENABLE_DEVICE=ON \
    -DHIPBLASLT_ENABLE_HOST=OFF \
    -DHIPBLASLT_ENABLE_CLIENT=OFF \
    -DHIPBLASLT_ENABLE_MSGPACK=OFF \
    -DHIPBLASLT_ENABLE_ROCROLLER=OFF \
    -DTENSILELITE_ENABLE_HOST=OFF \
    -DHIPBLASLT_ENABLE_LAZY_LOAD=ON \
    -DGPU_TARGETS=gfx90a \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_COMPILER=/opt/rocm-7.1.0/bin/amdclang++ \
    -DCMAKE_C_COMPILER=/opt/rocm-7.1.0/bin/amdclang \
    -DCMAKE_ASM_COMPILER=/opt/rocm-7.1.0/bin/amdclang++ \
    -DTENSILELITE_BUILD_PARALLEL_LEVEL=8

OMNIPROBE_INSTRUMENT_PLUGIN=$PLUGIN \
cmake --build $SANDBOX/hipblaslt-build -- -j8
```

Key configuration notes:
- `HIPBLASLT_ENABLE_HOST=OFF` and `TENSILELITE_ENABLE_HOST=OFF`: Skip the
  host library build (we symlink the system one instead).
- `HIPBLASLT_ENABLE_LAZY_LOAD=ON`: Required when host is disabled, prevents
  duplicate symbol linker errors in TensileLite.
- `CMAKE_ASM_COMPILER`: Must be set to `amdclang++` for ExtOps assembly.

### 2c: Create custom hipBLASLt installation

The hipBLASLt host library (`libhipblaslt.so`) uses `dladdr()` to find its
own directory, then looks for device code objects in `../hipblaslt/library/`
relative to itself. By symlinking the system host library into a custom
directory, it will find our instrumented device code objects.

```bash
CUSTOM_DIR=$SANDBOX/hipblaslt-install
mkdir -p $CUSTOM_DIR/lib/hipblaslt/library

# Symlink system host library
ln -sf /opt/rocm-7.1.0/lib/libhipblaslt.so.* $CUSTOM_DIR/lib/
cd $CUSTOM_DIR/lib
ln -sf libhipblaslt.so.1 libhipblaslt.so

# Copy device code objects from build
cp $SANDBOX/hipblaslt-build/Tensile/library/* $CUSTOM_DIR/lib/hipblaslt/library/
```

### 2d: Unbundle and verify

The matrix transform hsaco is a Clang Offload Bundle. Unbundle it for the
library filter:

```bash
clang-offload-bundler \
    --unbundle --type=o \
    --targets=hipv4-amdgcn-amd-amdhsa--gfx90a \
    --input=$CUSTOM_DIR/lib/hipblaslt/library/hipblasltTransform.hsaco \
    --output=$CUSTOM_DIR/lib/hipblaslt/library/hipblasltTransform-gfx90a.hsaco

# Verify instrumented symbols
nm $CUSTOM_DIR/lib/hipblaslt/library/hipblasltTransform-gfx90a.hsaco | grep __amd_crk_ | wc -l
# Expected: ~960 instrumented symbols
```

## Step 3: Build rocBLAS with instrumentation

### 3a: Configure

```bash
cmake \
    -B $SANDBOX/rocblas-build \
    -S $SANDBOX/rocm-libraries/projects/rocblas \
    -DCMAKE_TOOLCHAIN_FILE=$SANDBOX/rocm-libraries/projects/rocblas/toolchain-linux.cmake \
    -DROCM_PATH=/opt/rocm-7.1.0 \
    -DCMAKE_INSTALL_PREFIX=$SANDBOX/rocblas-install \
    -DCMAKE_PREFIX_PATH="/opt/rocm-7.1.0;$CUSTOM_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGPU_TARGETS="gfx90a" \
    -DTensile_LOGIC=hip_full \
    -DTensile_LAZY_LIBRARY_LOADING=OFF \
    -DTensile_SEPARATE_ARCHITECTURES=ON \
    -DTensile_LIBRARY_FORMAT=yaml \
    -DBUILD_WITH_HIPBLASLT=ON \
    -Dhipblaslt_path=$CUSTOM_DIR \
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
        "/path/to/hipblaslt-install/lib/hipblaslt/library/hipblasltTransform-gfx90a.hsaco"
    ]
}
EOF

LD_LIBRARY_PATH=$SANDBOX/rocblas-install/lib:$SANDBOX/hipblaslt-install/lib:$LD_LIBRARY_PATH \
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

## Environment Variables Reference

| Variable | Purpose |
|---|---|
| `OMNIPROBE_INSTRUMENT_PLUGIN` | Path to the instrumentation plugin .so file |
| `ROCBLAS_USE_HIPBLASLT` | `0` to disable hipBLASLt, `1` to force it |
| `HIPBLASLT_TENSILE_LIBPATH` | Override path to TensileLite kernel library |
| `HIPBLASLT_EXT_OP_LIBRARY_PATH` | Override path to extension operations library |
| `HIPBLASLT_LOG_LEVEL` | Set to `info` for debug logging |
| `Tensile_CXX_COMPILER_LAUNCHER` | Compiler launcher for Tensile builds |
| `ROCR_VISIBLE_DEVICES` | GPU device selection for testing |


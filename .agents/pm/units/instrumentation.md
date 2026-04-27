# Instrumentation

## Responsibility

LLVM IR instrumentation plugins that clone kernels at compile time and insert instrumentation calls. The original kernel is preserved; the clone receives an extra argument for dh_comms communication.

## Key Source Files

| File | Purpose |
|------|---------|
| `src/instrumentation/AMDGCNSubmitAddressMessages.cpp` | Address message instrumentation |
| `src/instrumentation/AMDGCNSubmitBBStart.cpp` | Basic block entry tracking |
| `src/instrumentation/AMDGCNSubmitBBInterval.cpp` | Basic block timing |
| `src/instrumentation/InstrumentationCommon.cpp` | Shared instrumentation logic |
| `src/instrumentation/include/` | Headers for instrumentation plugins |
| `cmake_modules/add_instrumentation_plugins.cmake` | CMake function for building plugins |

## Key Types and Classes

N/A — LLVM pass plugins, no user-defined classes.

## Key Functions and Entry Points

| Function | Location | Purpose |
|----------|----------|---------|
| `add_instrumentation_plugins()` | `cmake_modules/add_instrumentation_plugins.cmake` | CMake function, called once per LLVM variant |

## Data Flow

1. Compile time: LLVM pass plugin loaded via `-fpass-plugin`
2. Plugin clones each kernel, creates instrumented variant with `_inst` suffix
3. Instrumented variant gets extra `void* dh_comms_descriptor` argument
4. At runtime, interceptor finds and swaps to instrumented variant

### Plugins Produced

| Plugin | Instruments | dh_comms Calls | Used By Analyzers |
|--------|-------------|----------------|-------------------|
| AMDGCNSubmitAddressMessages | Load/Store | `v_submit_address()` | AddressLogger, Heatmap, MemoryAnalysis (default) |
| AMDGCNSubmitBBStart | Basic blocks | `s_submit_wave_header()` | BasicBlockLogger, BasicBlockAnalysis |
| AMDGCNSubmitBBInterval | BB timing | `s_submit_time_interval()` | (none - available but unused) |

### Build System

Plugins are compiled using `add_custom_command()` with the LLVM variant's own `clang++` (from `llvm-config --bindir`), NOT `hipcc`. This is required because LLVM pass plugins must match the LLVM they will be loaded into.

- **ROCm:** `add_instrumentation_plugins(SUFFIX rocm LLVM_DIR ${ROCM_PATH}/llvm)`
- **Triton:** `add_instrumentation_plugins(SUFFIX triton LLVM_DIR ${TRITON_LLVM} LINK_LLVM_LIBS)`

### Bitcode Location

Bitcode is located via `getBitcodePath()`: looks in `../bitcode/` relative to the plugin directory.

### InstrumentationScope

Reads `INSTRUMENTATION_SCOPE` and `INSTRUMENTATION_SCOPE_FILE` environment variables at compile time to restrict which instructions are instrumented. Syntax: `file[:N[:M][,N[:M]...]][;...]`

### Address Space Mapping

| Address Space ID | Name |
|------------------|------|
| 0 | FLAT |
| 1 | GLOBAL |
| 3 | SHARED |
| 4 | CONSTANT |

DWARF source location is encoded in messages for correlation with source code.

## Invariants

- Plugin must match LLVM version (ROCm vs Triton builds are separate)
- Instrumented kernel suffix is always `_inst`
- dh_comms descriptor is passed as the final kernel argument
- Address space mapping: FLAT(0), GLOBAL(1), SHARED(3), CONSTANT(4)
- DWARF source location is encoded in messages

## Dependencies

- **sub-dh-comms** — device-side bitcode for message submission. Also load: `sub-dh-comms.md`

## Negative Knowledge

- This was formerly a separate submodule (`instrument-amdgpu-kernels`). It was absorbed into `src/instrumentation/` on 2026-03-24. Do NOT treat it as a submodule or look for it under `external/`.
- Default plugin is `libAMDGCNSubmitAddressMessages`. HIP mode requires manual compilation with `-fpass-plugin`; Triton mode sets `LLVM_PASS_PLUGIN_PATH` automatically.
- `libAMDGCNSubmitBBInterval-triton.so` exists but no analyzer currently uses it.

## Open Questions

None.

## Last Verified

- 2026-03-24

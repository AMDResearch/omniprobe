# Instrumentation Plugins (formerly instrument-amdgpu-kernels submodule)

## Location
`src/instrumentation/` (absorbed from submodule, refactor `rf_absorb-instrumentation-plugins`, done)

## Role in Omniprobe
LLVM IR instrumentation plugins. At compile time, clones kernels and inserts instrumentation calls. The original kernel is preserved; the clone is suffixed and receives an extra argument.

## Build System
Plugins are built via `add_instrumentation_plugins()` function in
`cmake_modules/add_instrumentation_plugins.cmake`. Called once per LLVM variant:
- ROCm: `add_instrumentation_plugins(SUFFIX rocm LLVM_DIR ${ROCM_PATH}/llvm)`
- Triton: `add_instrumentation_plugins(SUFFIX triton LLVM_DIR ${TRITON_LLVM} LINK_LLVM_LIBS)`

**Key design**: Plugins are compiled using `add_custom_command()` with the LLVM variant's own
`clang++` (from `llvm-config --bindir`), NOT hipcc. This is required because LLVM pass plugins
must match the LLVM they'll be loaded into.

## Plugins Produced
- `libAMDGCNSubmitAddressMessages-{rocm,triton}.so` — address message instrumentation
- `libAMDGCNSubmitBBStart-{rocm,triton}.so` — basic block entry tracking
- `libAMDGCNSubmitBBInterval-{rocm,triton}.so` — basic block timing

All plugins use dh_comms bitcode for device-side message submission.
Bitcode located via `getBitcodePath()`: looks in `../bitcode/` relative to plugin dir
(i.e., `lib/bitcode/` when plugin is in `lib/plugins/`), with fallback to same directory.

## Key Concepts
- **Kernel Cloning**: Original kernel `foo` → instrumented `foo_inst`
- **Extra Argument**: Instrumented kernel gets `void* dh_comms_descriptor`
- **Address Space Mapping**: FLAT(0), GLOBAL(1), SHARED(3), CONSTANT(4)
- **DWARF Embedding**: Source location encoded in messages

## Omniprobe Usage
1. Build with `LLVM_PASS_PLUGIN_PATH` pointing to plugin
2. Executable contains both original and instrumented kernels
3. liblogDuration intercepts dispatch, finds `_inst` variant
4. Modifies kernarg to include dh_comms descriptor pointer

## Key Integration Invariants
- Plugin must match LLVM version (ROCm vs Triton)
- Instrumented kernel suffix: `_inst` (configurable?)
- dh_comms descriptor passed as final kernel argument

## Compile-Time Scope Filtering
`InstrumentationScope` class in InstrumentationCommon reads `INSTRUMENTATION_SCOPE` and
`INSTRUMENTATION_SCOPE_FILE` env vars at compile time to restrict which instructions are
instrumented based on source file and line range. When active, instructions without debug
info are skipped. Syntax: `file[:N[:M][,N[:M]...]][;...]` — see rf_instrumentation-scope.md.

## Instrumentation Types

| Plugin | Instruments | dh_comms Calls | Used By Analyzers |
|--------|-------------|----------------|-------------------|
| AMDGCNSubmitAddressMessages | Load/Store | `v_submit_address()` | AddressLogger, Heatmap, MemoryAnalysis (default) |
| AMDGCNSubmitBBStart | Basic blocks | `s_submit_wave_header()` | BasicBlockLogger, BasicBlockAnalysis |
| AMDGCNSubmitBBInterval | BB timing | `s_submit_time_interval()` | *(none - available but unused)* |

**Plugin Selection**:
- **Default plugin**: `libAMDGCNSubmitAddressMessages-{rocm,triton}.so` used unless analyzer overrides
- **Triton mode**: Omniprobe sets `LLVM_PASS_PLUGIN_PATH` automatically based on selected analyzer
- **HIP mode**: Users must manually compile with `-fpass-plugin=<plugin>.so`

## Directory Structure

```
src/instrumentation/
├── AMDGCNSubmitAddressMessages.cpp
├── AMDGCNSubmitBBStart.cpp
├── AMDGCNSubmitBBInterval.cpp
├── InstrumentationCommon.cpp
└── include/
    ├── AMDGCNSubmitAddressMessage.h
    ├── AMDGCNSubmitBBInterval.h
    ├── AMDGCNSubmitBBStart.h
    ├── InstrumentationCommon.h
    └── utils.h
```

## Last Verified
Commit: 49f4138
Date: 2026-03-24

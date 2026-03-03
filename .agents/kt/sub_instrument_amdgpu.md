# instrument-amdgpu-kernels (Sub-project Integration)

## Location
`external/instrument-amdgpu-kernels/` (git submodule)

## Sub-project KT
`external/instrument-amdgpu-kernels/.agents/kt/architecture.md`

## Role in Omniprobe
LLVM IR instrumentation plugins. At compile time, clones kernels and inserts instrumentation calls. The original kernel is preserved; the clone is suffixed and receives an extra argument.

**Recent Changes** (2026-03-03):
- Removed 5 plugins that don't use dh_comms bitcode
- Simplified to 3 core plugins: AddressMessages, BBStart, BBInterval
- Removed examples/, instrumentation/, tests/ directories
- Renamed lib/ → src/

## Integration Points

### Plugins Produced
- `libAMDGCNSubmitAddressMessages-{rocm,triton}.so` — address message instrumentation
- `libAMDGCNSubmitBBStart-{rocm,triton}.so` — basic block entry tracking
- `libAMDGCNSubmitBBInterval-{rocm,triton}.so` — basic block timing

All plugins use dh_comms bitcode for device-side message submission.

### Key Concepts
- **Kernel Cloning**: Original kernel `foo` → instrumented `foo_inst`
- **Extra Argument**: Instrumented kernel gets `void* dh_comms_descriptor`
- **Address Space Mapping**: FLAT(0), GLOBAL(1), SHARED(3), CONSTANT(4)
- **DWARF Embedding**: Source location encoded in messages

### Omniprobe Usage
1. Build with `LLVM_PASS_PLUGIN_PATH` pointing to plugin
2. Executable contains both original and instrumented kernels
3. liblogDuration intercepts dispatch, finds `_inst` variant
4. Modifies kernarg to include dh_comms descriptor pointer

## Key Integration Invariants
- Plugin must match LLVM version (ROCm vs Triton)
- Instrumented kernel suffix: `_inst` (configurable?)
- dh_comms descriptor passed as final kernel argument

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

## Also Load
- Full sub-project KT at `external/instrument-amdgpu-kernels/.agents/kt/architecture.md` (when available)

## Directory Structure (Simplified)

```
instrument-amdgpu-kernels/
├── src/                        # Plugin source (renamed from lib/)
│   ├── AMDGCNSubmitAddressMessages.cpp
│   ├── AMDGCNSubmitBBStart.cpp
│   ├── AMDGCNSubmitBBInterval.cpp
│   ├── InstrumentationCommon.cpp
│   └── CMakeLists.txt
├── include/                    # Public headers
└── CMakeLists.txt
```

## Last Verified
Submodule commit: 5a5d7e0
Date: 2026-03-03

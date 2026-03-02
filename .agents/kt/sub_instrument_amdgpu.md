# instrument-amdgpu-kernels (Sub-project Integration)

## Location
`external/instrument-amdgpu-kernels/` (git submodule)

## Sub-project KT
`external/instrument-amdgpu-kernels/.agents/kt/` (not yet initialized)

## Role in Omniprobe
LLVM IR instrumentation plugins. At compile time, clones kernels and inserts instrumentation calls. The original kernel is preserved; the clone is suffixed and receives an extra argument.

## Integration Points

### Plugins Produced
- `libAMDGCNSubmitAddressMessages-rocm.so` — address message instrumentation (ROCm LLVM)
- `libAMDGCNSubmitAddressMessages-triton.so` — same, for Triton LLVM
- `libAMDGCNMemTrace.so` — memory trace instrumentation
- `libAMDGCNNumCacheLines.so` — cache line counting

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

| Plugin | Instruments | Message Content |
|--------|-------------|-----------------|
| AMDGCNSubmitAddressMessages | Load/Store | 64 addresses + DWARF + access size |
| AMDGCNMemTrace | Load/Store | Full trace |
| AMDGCNNumCacheLines | Load/Store | Cache line count |

## Also Load
- Full sub-project KT at `external/instrument-amdgpu-kernels/.agents/kt/architecture.md` (when available)

## Last Verified
Date: 2026-03-02

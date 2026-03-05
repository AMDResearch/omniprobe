# kerneldb (Sub-project Integration)

## Location
`external/kerneldb/` (git submodule)

## Sub-project KT
`external/kerneldb/.agents/kt/` (not yet initialized)

## Role in Omniprobe
Kernel database for ISA extraction and DWARF correlation. Provides:
- Disassembly extraction from HIP/ROCm executables
- DWARF debug info parsing (file, line, column)
- Mapping from source locations to ISA instructions
- Kernel argument introspection

## Integration Points

### Headers Used
- `kernelDB.h` — main API

### Key Types
- `kernelDB::kernelDB` — per-executable database of kernels
- `kernelDB::CDNAKernel` — single kernel with basic blocks + instructions
- `kernelDB::basicBlock` — instruction container
- `kernelDB::instruction_t` — parsed instruction with DWARF info
- `SourceLocation` — file/line/column tuple
- `KernelArgument` — argument metadata

### Omniprobe Usage
1. Interceptor creates `kernelDB` per agent when code object loaded (no scanning at startup)
2. At dispatch time, `scanCodeObject(co_file)` performs lazy on-demand scanning (disassembly + DWARF + args) for the dispatched kernel's code object
3. `hasKernel(name)` checks if a kernel is already known (avoids redundant scans)
4. Message handlers query ISA instructions for source locations
5. Memory analysis uses ISA access size to correct IR-level analysis
6. Disassembly used for reporting

### Key APIs Added (2026-03-05)
- `scanCodeObject(co_file)` — lazy full-disassembly + DWARF mapping + argument extraction for a single code object; idempotent (tracked via `scanned_code_objects_` set)
- `hasKernel(name)` — thread-safe check if kernel exists in `kernels_` map

## Key Integration Invariants
- kernelDB populated on-demand at dispatch time (not at startup)
- DWARF info must be present in executable (-g flag)
- ISA instruction size may differ from IR (dwordx4 optimization)

## ISA Size Correction
IR-level instrumentation sees individual dword accesses in loops. Backend may optimize to single dwordx4 instruction. Handler queries kerneldb to get actual ISA access size and correct analysis.

## Also Load
- Full sub-project KT at `external/kerneldb/.agents/kt/architecture.md` (when available)

## Last Verified
Date: 2026-03-05

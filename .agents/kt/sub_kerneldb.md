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
1. Interceptor creates `kernelDB` per agent when code object loaded
2. Message handlers query ISA instructions for source locations
3. Memory analysis uses ISA access size to correct IR-level analysis
4. Disassembly used for reporting

## Key Integration Invariants
- kernelDB populated from executable code objects
- DWARF info must be present in executable (-g flag)
- ISA instruction size may differ from IR (dwordx4 optimization)

## ISA Size Correction
IR-level instrumentation sees individual dword accesses in loops. Backend may optimize to single dwordx4 instruction. Handler queries kerneldb to get actual ISA access size and correct analysis.

## Also Load
- Full sub-project KT at `external/kerneldb/.agents/kt/architecture.md` (when available)

## Last Verified
Date: 2026-03-02

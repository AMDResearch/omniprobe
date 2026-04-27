# Sub-project: kerneldb

## Responsibility

Kernel database for ISA extraction and DWARF correlation (git submodule at `external/kerneldb/`).
Provides disassembly extraction from HIP/ROCm executables, DWARF debug info parsing,
mapping from source locations to ISA instructions, and kernel argument introspection.

## Key Source Files

- `external/kerneldb/` — git submodule root
- `kernelDB.h` — main API (headers)

## Key Types and Classes

| Type | Header | Role |
|------|--------|------|
| `kernelDB::kernelDB` | `kernelDB.h` | Per-executable database of kernels |
| `kernelDB::CDNAKernel` | `kernelDB.h` | Single kernel with basic blocks + instructions |
| `kernelDB::basicBlock` | `kernelDB.h` | Instruction container |
| `kernelDB::instruction_t` | `kernelDB.h` | Parsed instruction with DWARF info |
| `SourceLocation` | `kernelDB.h` | File/line/column tuple |
| `KernelArgument` | `kernelDB.h` | Argument metadata |

## Key Functions and Entry Points

| Function | Header | Notes |
|----------|--------|-------|
| `kernelDB::scanCodeObject(co_file)` | `kernelDB.h` | Lazy full-disassembly + DWARF mapping for a single code object; idempotent |
| `kernelDB::hasKernel(name)` | `kernelDB.h` | Thread-safe check if kernel exists |
| `kernelDB::addFile(path, agent, filter, lazy)` | `kernelDB.h` | With `lazy=true`, indexes kernel names from ELF symbol table without disassembling |
| `kernelDB::ensureKernelLoaded(name)` | `kernelDB.h` | (internal) Disassembles a single kernel on demand, thread-safe |
| `kernelDB::getKernelNamesFromElf(fileName)` | `kernelDB.h` | (private) Reads `.symtab` for kernel names without disassembly |
| `kernelDB::extractCodeObjects()` | `kernelDB.h` | Supports CCOB (Compressed Clang Offload Bundle) files |

## Data Flow

1. Interceptor creates `kernelDB` per agent when code object loaded (no scanning at startup).
2. At dispatch time, `scanCodeObject(co_file)` performs lazy on-demand scanning.
3. `hasKernel(name)` checks if a kernel is already known (avoids redundant scans).
4. Message handlers query ISA instructions for source locations.
5. Memory analysis uses ISA access size to correct IR-level analysis.

## Invariants

- `kernelDB` populated on-demand at dispatch time (not at startup).
- DWARF info must be present in executable (`-g` flag).
- ISA instruction size may differ from IR (`dwordx4` optimization).
- Use `git -C` for submodule git operations.

## Dependencies

None (leaf submodule).

## Negative Knowledge

- Sub-project KT at `external/kerneldb/.agents/kt/` may not be initialized yet.

## Open Questions

None.

## Last Verified

2026-04-27 (removed transient workflow reference per pm-reflect)

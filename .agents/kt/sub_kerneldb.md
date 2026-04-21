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
- `hasKernel(name)` — thread-safe check if kernel exists in `kernels_` map (also checks `lazy_kernels_`)
- `extractCodeObjects()` now supports CCOB (Compressed Clang Offload Bundle) files:
  - Standalone `.co` files: detected by CCOB magic, unbundled via `clang-offload-bundler`
  - Compressed `.hip_fatbin` sections: multi-block CCOB parsing + per-block unbundling
  - Transparent to callers — returns temp file paths regardless of compression

### APIs Added by PR #27 (2026-04-14, lazy loading)
- `addFile(path, agent, filter, lazy=true)` — with `lazy=true`, indexes kernel names from
  ELF symbol table without disassembling. Disassembly deferred to first query.
- `ensureKernelLoaded(name)` — (internal, called by `getKernel`, `getInstructionsForLine`,
  `getFileName`, `getKernelLines`) disassembles a single kernel on demand. Thread-safe via
  `loading_mutex_` + `condition_variable` sentinel pattern.
- `getKernelNamesFromElf(fileName)` — (private) reads `.symtab` to get kernel names without
  disassembly; used by `addFile(lazy=true)`.
- `getDisassemblyForSymbol(agent, file, symbol, out)` — targeted disassembly via
  `llvm-objdump --disassemble-symbols`.

### Pending Refactor: Lazy Loading Adoption
See `rf_lazy-kerneldb-loading.md`. Omniprobe currently uses `scanCodeObject()` (disassembles
entire code object). Plan: switch to `addFile(lazy=true)` at startup, remove dispatch-time
`scanCodeObject` block, let handlers trigger per-kernel loading via `ensureKernelLoaded()`.
Status: Ready to start.

## Key Integration Invariants
- kernelDB populated on-demand at dispatch time (not at startup)
- DWARF info must be present in executable (-g flag)
- ISA instruction size may differ from IR (dwordx4 optimization)

## ISA Size Correction
IR-level instrumentation sees individual dword accesses in loops. Backend may optimize to single dwordx4 instruction. Handler queries kerneldb to get actual ISA access size and correct analysis.

## Also Load
- Full sub-project KT at `external/kerneldb/.agents/kt/architecture.md` (when available)

## Last Verified
Commit: 2dcea70
Date: 2026-04-14

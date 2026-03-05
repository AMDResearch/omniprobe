# Refactor: Clang Offload Bundle (CCOB) Support

## Status
- [x] TODO
- [ ] In Progress
- [ ] Blocked
- [ ] Done

## Objective
Add support for reading compressed Clang Offload Bundle files (CCOB format) to enable omniprobe to find instrumented kernel alternatives in:
1. Tensile `.co` files (lazy-loaded kernel libraries)
2. Compressed `.hip_fatbin` sections in `.so` files (e.g., librocblas.so with offload compression)

## Refactor Contract

### Goal
Enable omniprobe/kernelDB to transparently read GPU code objects from compressed Clang Offload Bundle files, using either:
- Shell out to `clang-offload-bundler --unbundle`
- Direct library integration (if feasible)

### Non-Goals / Invariants
- ABI compatibility: n/a (internal change)
- API compatibility: Existing file scanning should continue to work unchanged
- Performance constraints: Decompression adds latency; consider caching decompressed files
- Threading model: No changes to existing threading
- Other invariants:
  - Uncompressed bundles (`__CLANG_OFFLOAD_BUNDLE__`) should continue to work
  - Fallback gracefully if clang-offload-bundler not available

### Verification Gates
- Build: `cd build && ninja`
- Tests: Existing tests pass + new tests for CCOB files
- Runtime: Successfully find instrumented alternatives in rocBLAS Tensile kernels

## Background

### Clang Offload Bundle Format

Two variants exist:

| Magic Bytes | Format | Description |
|-------------|--------|-------------|
| `__CLANG_OFFLOAD_BUNDLE__` | Uncompressed | Standard bundle, directly readable |
| `CCOB` | Compressed | Compressed bundle, requires decompression |

### Where CCOB is used

1. **Tensile `.co` files** (lazy library loading)
   - Created by `clang-offload-bundler --compress`
   - Contains optimized kernels for specific matrix sizes
   - Always compressed regardless of `BUILD_OFFLOAD_COMPRESS` flag

2. **`.hip_fatbin` sections in `.so` files** (when `BUILD_OFFLOAD_COMPRESS=ON`)
   - Embedded in ELF shared libraries
   - Contains non-Tensile GPU kernels
   - Controlled by `BUILD_OFFLOAD_COMPRESS` CMake flag

### Decompression

Both formats can be decompressed using:
```bash
clang-offload-bundler --type=o --unbundle \
  --targets=hipv4-amdgcn-amd-amdhsa--gfx90a \
  --input=compressed.co \
  --output=decompressed.hsaco
```

The tool is part of ROCm LLVM: `/opt/rocm-X.Y.Z/lib/llvm/bin/clang-offload-bundler`

### Validation (2026-03-04)

Successfully decompressed a Tensile `.co` file:
- Input: `TensileLibrary_Type_SS_Contraction_l_Ailk_Bljk_Cijk_Dijk_gfx90a.co` (598KB, CCOB)
- Output: `/tmp/tensile_ss_gfx90a.hsaco` (10.9MB, ELF)
- Contains instrumented kernels with `__amd_crk_` prefix

## Scope

### Affected Symbols
- `kernelDB::addFile()` — needs to detect and decompress CCOB files
- `KernelArgHelper::getClangOffloadBundles()` or similar — may need CCOB handling
- Potentially `LibraryFilter` if include paths point to `.co` files

### Expected Files
- `external/kerneldb/src/kernelDB.cc` — main file scanning logic [hypothesis]
- `src/utils.cc` — may have bundle handling code [hypothesis]
- New utility function for CCOB detection/decompression

### Risks
- **External tool dependency**: Requires `clang-offload-bundler` from ROCm
- **Performance**: Decompression adds latency; large files may be slow
- **Temp file management**: Need to clean up decompressed files
- **GPU architecture detection**: Need to know target arch for unbundling

### Mitigations
- Cache decompressed files (e.g., in `/tmp` or configurable location)
- Lazy decompression (only decompress when kernel actually needed)
- Detect ROCm installation path from existing config

## Plan of Record

### Approach Options

**Option A: Shell out to clang-offload-bundler**
- Pros: Simple, uses existing tested tool, no new dependencies
- Cons: External process overhead, need to handle errors

**Option B: Link against LLVM OffloadBundler library**
- Pros: No external process, potentially faster
- Cons: Complex LLVM linking, version compatibility issues

**Recommended: Option A** (shell out) for initial implementation, with Option B as future optimization.

### Micro-steps (preliminary)

1. [ ] Survey kernelDB code to understand current file scanning flow
2. [ ] Add CCOB magic detection function (`isCCOB()`)
3. [ ] Add decompression function using clang-offload-bundler
4. [ ] Integrate decompression into addFile() or bundle extraction
5. [ ] Add temp file caching to avoid repeated decompression
6. [ ] Test with Tensile `.co` files
7. [ ] Test with compressed librocblas.so `.hip_fatbin` section
8. [ ] Add automated tests
9. [ ] Update documentation

### Current Step
Not started - awaiting approval to begin

## Dependencies

### Unblocks
- **rf_library-filter**: rocBLAS Tensile kernel validation (currently blocked on CCOB support)

### Requires
- ROCm installation with `clang-offload-bundler`
- Test rocBLAS build with Tensile kernels

## Open Questions
1. Should decompressed files be cached persistently or per-session?
2. How to handle multiple GPU architectures in a single `.co` file?
3. Should we support in-memory decompression (no temp files)?

## Progress Log
<!-- Append updates, don't delete -->

### Session 2026-03-04 (planning)
- Investigated CCOB format during library-filter rocBLAS validation
- Discovered both Tensile `.co` and compressed `.hip_fatbin` use same format
- Validated decompression with clang-offload-bundler works
- Created this dossier

## Rejected Approaches
None yet.

## Last Verified
Commit: N/A
Date: 2026-03-04

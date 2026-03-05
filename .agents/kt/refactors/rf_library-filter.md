# Refactor: Library Include/Exclude Filtering

## Status
- [ ] TODO
- [ ] In Progress
- [x] Blocked
- [ ] Done

### Blocker
**rocBLAS Tensile kernels use compressed .co files (CCOB format)**

rocBLAS with lazy loading stores optimized Tensile kernels in compressed `.co` files, not `.hsaco`:
- `.hsaco` files only contain fallback (generic) kernels
- Optimized kernels (dispatched at runtime) are in `.co` files with CCOB header
- omniprobe cannot currently read CCOB-format files
- The `BUILD_OFFLOAD_COMPRESS=OFF` flag only affects `.hsaco` and `librocblas.so`, NOT the `.co` files

**To unblock**, one of:
1. Complete `rf_offload-compression` refactor (adds CCOB support to omniprobe)
2. Build rocBLAS with `-DTensile_LAZY_LIBRARY_LOADING=OFF` (produces only `.hsaco`, no `.co`)

**Dependency**: See `.agents/kt/refactors/rf_offload-compression.md` for CCOB support refactor.

**Investigation findings (2026-03-04):**
- Compared `build-without-offload-compression` vs `build-with-offload-compression`
- `.co` files: **Identical** in both builds (CCOB format, ~598KB each)
- `.hsaco` files: **Identical** in both builds (ELF uncompressed, ~231KB each)
- `librocblas.so`: 541MB vs 215MB (compression only affects this)
- `BUILD_OFFLOAD_COMPRESS` only affects librocblas.so, NOT Tensile files
- `Tensile_LAZY_LIBRARY_LOADING=ON` (default) causes `.co` file generation
- Setting `Tensile_LAZY_LIBRARY_LOADING=OFF` should produce only `.hsaco` files

**Related improvements to consider:**
- Kernel scanning is slow (scans all kernels upfront). Should be lazy/on-demand for dispatched kernels only.
- Currently scans twice: once at dispatch (fast), once for disassembly/instrumented versions (slow).

## Objective
Add library include/exclude filtering to omniprobe to speed up scanning by allowing users to skip irrelevant libraries and add additional files (e.g., rocBLAS code objects loaded via `dlopen`).

## Refactor Contract

### Goal
Implement a `--library-filter FILE` CLI argument that accepts a JSON config file with three lists:
- `include`: Add specific files to scan (exact file only)
- `include_with_deps`: Add files + their ELF dependencies (recursive)
- `exclude`: Remove files from scanning (always wins, applied last)

### Non-Goals / Invariants
- ABI compatibility: n/a (new feature)
- API compatibility: n/a (new feature)
- Performance constraints: Filtering should not add significant overhead; goal is to REDUCE scan time
- Threading model: No changes to existing threading
- Other invariants:
  - Existing behavior unchanged when no `--library-filter` argument provided
  - Transitive exclusion preserved: excluding libA does NOT exclude libA's dependencies
  - Exclude always wins over include

### Verification Gates
- Build: `cd build && ninja`
- Tests: `cd tests && ./run_handler_tests.sh` (includes new library filter tests)
- Runtime: Manual verification with test configs

## Scope

### Affected Symbols
- `hsaInterceptor` constructor — add LibraryFilter initialization and application
- `getLogDurConfig()` — add LOGDUR_LIBRARY_FILTER env var reading
- New class: `LibraryFilter` — JSON parsing, glob-to-regex, dependency resolution

### Expected Files
- `inc/library_filter.h` — NEW, filter class declaration [to create]
- `src/library_filter.cc` — NEW, filter implementation [to create]
- `inc/interceptor.h` — add LibraryFilter member [confirmed]
- `src/interceptor.cc` — initialize filter, apply to library list (lines 189-222) [confirmed]
- `src/utils.cc` — add LOGDUR_LIBRARY_FILTER to getLogDurConfig() (around line 620) [confirmed]
- `omniprobe/omniprobe` — add --library-filter CLI argument (after line 630) [confirmed]
- `src/CMakeLists.txt` — add library_filter.cc to sources [confirmed]
- `tests/run_handler_tests.sh` — add library filter tests [confirmed]

### Call Graph Impact
```
omniprobe CLI
  → setup_env() sets LOGDUR_LIBRARY_FILTER env var
    → hsaInterceptor constructor reads config via getLogDurConfig()
      → LibraryFilter::loadConfig() parses JSON
        → In HIP path: filter applied after getSharedLibraries()
          → kernel_cache_.addFile() called only for non-excluded files
```

### Risks
- **JSON parsing complexity**: Mitigate by keeping format simple, no nested objects
- **ELF dependency resolution**: May need libelf or ldd; mitigate by starting with simpler approach
- **Glob pattern edge cases**: Test thoroughly with various patterns

## Config File Format

```json
{
  "include": ["/path/to/exact/file.so"],
  "include_with_deps": ["/opt/rocblas/lib/*.so"],
  "exclude": ["/lib64/libm.so.6", "/opt/ohpc/**"]
}
```

### Processing Order (Option B semantics)
1. Start with libraries from `dl_iterate_phdr()` (auto-discovered)
2. Add `include` files (exact match only)
3. Add `include_with_deps` files + their ELF dependencies
4. Remove duplicates
5. Apply `exclude` patterns (exclude always wins)

### Pattern Semantics
- `*` — matches any characters except `/`
- `**` — matches any characters including `/` (recursive)
- Patterns matched against full absolute paths
- Standard JSON (no comments)

## Plan of Record

### Test-Driven Development Approach

**Phase 1: Initial Tests (before implementation)**

Based on current scanning output from `tests/test_output/results.txt`, these libraries are scanned:
- ROCm libraries (e.g., `libamdhip64.so`)
- System libraries (`/lib64/libm.so.6`, `/lib64/libc.so.6`, etc.)
- Handler plugins (e.g., `libMemAnalysis64.so`)

### Micro-steps

**Phase 1: TDD Setup**
1. [x] Add test helper function `run_library_filter_test()` to `run_handler_tests.sh` — Gate: script runs
2. [x] Test 1: Exclude non-existent library (baseline) — Gate: test passes
3. [x] Test 2: Exclude `/lib64/libm.so.6` — Gate: test passes
4. [x] Test 3: Include `/lib64/libcrypt.so.2` — Gate: test passes

**Phase 2: Basic Implementation**
5. [x] Add `--library-filter` CLI argument to `omniprobe/omniprobe` — Gate: compile, help shows arg
6. [x] Add `LOGDUR_LIBRARY_FILTER` to `getLogDurConfig()` in `src/utils.cc` — Gate: compile
7. [x] Create `inc/library_filter.h` with class declaration — Gate: compile
8. [x] Create `src/library_filter.cc` with JSON parsing and glob-to-regex — Gate: compile
9. [x] Update `src/CMakeLists.txt` to include library_filter.cc — Gate: build succeeds
10. [x] Add `LibraryFilter` member to `inc/interceptor.h` — Gate: compile
11. [x] Integrate filter in `src/interceptor.cc` constructor — Gate: compile, Test 2 passes

**Phase 3: Include Support**
12. [x] Implement `getIncludedFiles()` with glob expansion — Gate: compile
13. [x] Integrate include files in interceptor — Gate: Test 3 passes

**Phase 4: Comprehensive Test Infrastructure**
14. [x] Implement `isValidElf()` to check ELF magic bytes — Gate: compile
15. [x] Create `tests/library_filter_chain/` directory structure — Gate: exists
16. [x] Create lib_static_tail (no deps, simple kernel) — Gate: compiles standalone
17. [x] Create lib_static_mid (links lib_static_tail) — Gate: compiles
18. [x] Create lib_static_head (links lib_static_mid) — Gate: compiles
19. [x] Create lib_dynamic_tail, lib_dynamic_mid, lib_dynamic_head (same pattern) — Gate: compiles
20. [x] Create app (links lib_static_head, dlopen's lib_dynamic_head) — Gate: compiles
21. [x] Run without instrumentation to verify cross-library calls work — Gate: runs successfully
22. [x] Compile with instrumentation, run under omniprobe — Gate: static kernels instrumented, dynamic NOT
23. [x] Test: Exclude linked libs — Gate: test passes (static libs excluded, kernels not instrumented)
24. [x] Test: Include dlopen'd libs (without deps) — Gate: test passes (dynamic_head added + instrumented)
25. [x] Implement `getElfDependencies()` for include_with_deps — Gate: compile, uses libelf
26. [x] Test: Include dlopen'd libs with deps — Gate: test passes (all 3 dynamic libs added + instrumented)

**Phase 5: Test Script Refactoring**
27. [x] Split run_handler_tests.sh into feature-specific subscripts — Gate: all 12 tests pass
28. [x] Run full test suite — Gate: all tests pass

**Phase 6: Real-World Validation**
29. [x] Test with rocBLAS + Tensile kernels (dynamically loaded) — Gate: works as expected
30. [ ] Manual verification with other real applications — Gate: works as expected

### Current Step
Step 30: Manual verification with other real applications

**rocBLAS Validation Complete (Step 29):**
- Created test programs in `tests/rocblas_filter/`:
  - `test_rocblas_scal.cpp` — calls `rocblas_sscal` (BLAS Level 1, non-Tensile kernel)
  - `test_rocblas_gemm.cpp` — calls `rocblas_sgemm` (BLAS Level 3, Tensile kernel)
- Verified kernel detection works without library filter (via HSA symbol interception)
- Verified `exclude` works: excluding librocblas.so (567MB, 6000+ kernels) reduces init from >3min to <1sec
- Verified `include` works: adding Kernels.so hsaco file explicitly adds 232 kernels to cache
- Key insight: Tensile kernels loaded via `hsa_code_object_reader_create_from_memory` ARE auto-detected by HSA interception — no `include` needed for them
- `include_with_deps` is still valuable for adding .so files not auto-discovered by `dl_iterate_phdr`

**Test configs created:**
- `exclude_rocblas.json` — excludes librocblas.so for fast init
- `include_tensile.json` — includes Kernels.so hsaco explicitly

**Test script structure:**
- `test_common.sh` — shared utilities and counters
- `run_basic_tests.sh` — Heatmap/MemoryAnalysis handler tests
- `run_block_filter_tests.sh` — --filter-x/y/z tests
- `run_library_filter_tests.sh` — --library-filter tests
- `run_handler_tests.sh` — orchestrator that sources all subscripts

**All implementation and unit testing complete:**
- Core library-filter functionality working (include, include_with_deps, exclude)
- `getElfDependencies()` implemented using libelf (parses DT_NEEDED, resolves paths)
- `tests/library_filter_chain/` — 5 comprehensive tests passing
- Main test suite refactored into modular scripts (12 tests passing)

**Next:** Manual verification with other real applications (optional)

**Status: Ready to finish** — Consider completing with `/kt-refactor finish`

## Progress Log

### Session 2026-03-04 (session 4)
- Validated library-filter with rocBLAS:
  - Created `tests/rocblas_filter/` with test_rocblas_scal.cpp and test_rocblas_gemm.cpp
  - rocBLAS built with instrumentation (Tensile enabled) at `/work1/amd/rvanoo/repos/rocBLAS/build-without-offload-compression/`
  - Verified: scal calls `rocblas_sscal_2_kernel` (non-Tensile), gemm calls `Cijk_...` (Tensile)
  - Kernel dispatches detected via HSA symbol interception
  - Exclude filter dramatically speeds up init by skipping 6000+ kernel librocblas.so scan
  - Include filter successfully adds hsaco files to kernel cache

- **Discovered blocker**: rocBLAS Tensile uses compressed `.co` files (CCOB format)
  - `.hsaco` files only contain fallback kernels (e.g., `MT128x64x8`)
  - Optimized kernels dispatched at runtime (e.g., `MT64x32x32`) are in `.co` files
  - `.co` files start with `CCOB` header - compressed code object format
  - omniprobe cannot read CCOB files, so instrumented alternatives not found
  - `BUILD_OFFLOAD_COMPRESS=OFF` only affects `.hsaco` and `librocblas.so`, NOT `.co` files
  - Read `/work1/amd/rvanoo/repos/rocBLAS/Instrumentation.md` - confirms Tensile kernels ARE instrumented

- Identified future improvements:
  - Add CCOB decompression support to omniprobe
  - Make kernel scanning lazy/on-demand (currently scans all upfront)
  - Investigate why scanning happens twice (dispatch vs disassembly/instrumented)

- Status changed to BLOCKED pending resolution of CCOB support

### Session 2026-03-04 (session 3)
- Created comprehensive test infrastructure: `tests/library_filter_chain/`
  - 6 libraries in 2 chains (static_head/mid/tail, dynamic_head/mid/tail)
  - App links static chain, dlopen's dynamic chain
  - Verified baseline: static instrumented, dynamic not (without filter)
- Implemented test cases 3-5:
  - Exclude static libs (works - kernels not instrumented)
  - Include dynamic (no deps) - works
  - Include with deps - works after implementing getElfDependencies()
- Implemented `getElfDependencies()` using libelf:
  - Parses ELF DT_NEEDED entries from dynamic section
  - Resolves library names using parent dir, LD_LIBRARY_PATH, standard paths
  - All 3 dynamic libs now added + instrumented with include_with_deps
- Refactored test scripts into modular structure:
  - `test_common.sh` — shared utilities and counters
  - `run_basic_tests.sh`, `run_block_filter_tests.sh`, `run_library_filter_tests.sh`
  - Main `run_handler_tests.sh` orchestrates all (12 tests pass)
- Fixed KT documentation issues:
  - Removed hardcoded path in testing.md line 73
  - Added "Path Guidelines" section to architecture.md
- All tests passing: 12 main + 5 library_filter_chain
- Next session: Validate with rocBLAS + Tensile (real-world dlopen use case)

### Session 2026-03-04 (session 2)
- Completed Phase 1-3 (steps 1-13) + partial Phase 4
- Added `run_library_filter_test()` helper and 3 test cases to run_handler_tests.sh
- Added `--library-filter FILE` CLI argument to omniprobe Python script
- Created `LibraryFilter` class with JSON parsing, glob-to-regex, isExcluded(), getIncludedFiles()
- Integrated filter into hsaInterceptor constructor
- Fixed issue: kernelDB constructor was auto-discovering libraries, bypassing filter
  - Solution: Use single-arg kernelDB(agent) constructor, then manually add filtered files
- All 12 tests pass (9 existing + 3 new library filter tests)
- Remaining: ELF dependency resolution, additional edge case tests
- Next: Implement getElfDependencies() or add more tests

### Session 2026-03-04
- Created refactor dossier from planning session
- Decided on Option B semantics: include + include_with_deps + exclude
- exclude always wins (applied last)
- TDD approach with 7 test cases defined
- Next: Begin with test infrastructure (micro-step 1)

## Rejected Approaches

- **Four ordered lists (exclude, exclude_with_deps, include, include_with_deps)**: Too complex to reason about ordering semantics. What happens if exclude removes libA but include_with_deps adds libB which depends on libA?

- **exclude_with_deps list**: Rarely needed—excluding a library typically shouldn't also exclude its dependencies since they may be used by other libraries.

- **Ordered rules array `[{action, pattern}...]`**: More verbose, harder to write configs. Three lists with fixed processing order is simpler.

## Open Questions
None currently.

## Last Verified
Commit: uncommitted (working tree)
Date: 2026-03-04
Tests: 12/12 main tests + 5/5 library_filter_chain tests passing
Note: rocBLAS validation blocked on CCOB/.co file support

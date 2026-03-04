# Refactor: Library Include/Exclude Filtering

## Status
- [ ] TODO
- [x] In Progress
- [ ] Blocked
- [ ] Done

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
- `/opt/rocm-7.1.0/lib/libamdhip64.so.7`
- `/opt/ohpc/pub/compiler/gcc/12.2.0/lib64/libstdc++.so.6`
- `/lib64/libm.so.6`, `/lib64/libc.so.6`, etc.
- `/work1/amd/rvanoo/.local/lib/libMemAnalysis64.so`

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

**Phase 4: Advanced Features**
14. [x] Implement `isValidElf()` to check ELF magic bytes — Gate: compile
15. [ ] Implement `getElfDependencies()` for include_with_deps — Gate: compile
16. [x] Implement `getIncludedFilesWithDeps()` (basic, deps TODO) — Gate: compile
17. [ ] Test 4: Transitive exclusion preserved — Gate: test passes
18. [ ] Test 5: include_with_deps works — Gate: test passes
19. [ ] Test 6: Invalid include (README.md) handled gracefully — Gate: test passes
20. [ ] Test 7: Exclude overrides include — Gate: test passes

**Phase 5: Finalization**
21. [ ] Run full test suite — Gate: all tests pass
22. [ ] Manual verification with real application — Gate: works as expected

### Current Step
Step 15: Implement getElfDependencies() for include_with_deps

**State at suspension:**
- All code compiles and tests pass (12/12)
- Core exclude/include functionality working
- ELF dependency resolution is stubbed (returns empty)
- Ready to implement `getElfDependencies()` or add more test coverage

## Progress Log

### Session 2026-03-04 (continued)
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
Tests: 12/12 passing

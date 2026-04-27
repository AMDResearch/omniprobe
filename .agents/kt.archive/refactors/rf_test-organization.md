# Refactor: Standardize Test Directory Organization

## Status
- [x] TODO
- [ ] In Progress
- [ ] Blocked
- [ ] Done

## Objective

Establish a consistent structure for all test suites under `tests/`, and define
guidelines (or a skill) for creating new tests so future additions stay consistent.

## Problem Statement

The test directory has grown organically, and each suite follows its own conventions
for directory layout, build location, output location, and runner structure. This
makes it hard to understand the test infrastructure at a glance and leads to
inconsistency when adding new test suites.

### Current Inconsistencies

**Build location** — four different patterns:
1. Main CMake build dir (`build/tests/test_kernels/`) — test_kernels
2. Local in-tree build (`tests/library_filter_chain/build/`) — library_filter_chain
3. Pre-built binaries checked into the source tree — rocblas_filter, hipblaslt
4. No build / JIT — triton, rocblas_hipblaslt

**Output location** — two patterns:
1. Centralized: `tests/test_output/` — handler tests, rocblas_filter, rocblas_hipblaslt, hipblaslt
2. Local: `tests/<suite>/test_output/` — library_filter_chain, triton

**Runner structure** — three patterns:
1. Sourced subscripts with shared counters (handler tests via `test_common.sh`)
2. Standalone `run_test.sh` per suite (rocblas_filter, triton, hipblaslt, etc.)
3. Standalone with own build step (library_filter_chain)

**CMake integration**:
- Only `test_kernels/` is in the main CMake build
- `library_filter_chain/` has its own standalone CMakeLists.txt
- Other suites have no CMake integration (pre-built or JIT)

**Source vs binary**:
- Some suites have source + build infrastructure (test_kernels, library_filter_chain)
- Others have source files alongside pre-built binaries with no build integration
  (rocblas_filter, hipblaslt) — the .cpp files serve as documentation only

**Test helper functions** differ per suite:
- `run_test()` in run_basic_tests.sh
- `run_filter_test()` in run_block_filter_tests.sh
- `run_library_filter_test()` in run_library_filter_tests.sh
- Inline test logic in standalone scripts (rocblas, triton, hipblaslt)

### Current Layout
```
tests/
├── CMakeLists.txt                    (only covers test_kernels/)
├── handler_integration_test.cc       (dead code — GoogleTest, disabled)
├── run_all_tests.sh                  (orchestrator)
├── run_handler_tests.sh              (dispatcher — sources subscripts)
├── run_basic_tests.sh                (sourced subscript)
├── run_block_filter_tests.sh         (sourced subscript)
├── run_library_filter_tests.sh       (sourced subscript)
├── test_common.sh                    (shared utilities)
├── test_output/                      (centralized output — some suites)
├── test_kernels/                     (CMake-built HIP kernels)
├── library_filter_chain/             (standalone CMake + run_test.sh + local output)
├── rocblas_filter/                   (pre-built binaries + run_test.sh)
├── rocblas_hipblaslt/                (run_test.sh only — uses rocblas_filter binaries)
├── triton/                           (Python + run_test.sh + local output)
└── hipblaslt/                        (pre-built binary + run_test.sh)
```

## Refactor Contract

### Goal
1. Define a standard test suite layout (directory structure, naming, output location)
2. Migrate existing suites to the standard layout
3. Create a skill or template for adding new test suites consistently

### Non-Goals / Invariants
- Don't change what the tests actually test
- Don't break `run_all_tests.sh` orchestration
- Keep graceful skip behavior for suites requiring env vars
- Pre-built binaries may remain pre-built (not all suites can be CMake-integrated)

### Verification Gates
- Build: `cmake --build .` (in build directory)
- Tests: `./tests/run_all_tests.sh` (all suites pass, or skip gracefully as before)

## Scope

### Design Decisions Needed

1. **Output location**: Centralized `tests/test_output/` for all suites, or
   per-suite `tests/<suite>/test_output/`?

2. **Handler test scripts**: Should the sourced-subscript pattern (run_basic_tests.sh
   etc.) be migrated to standalone `run_test.sh` scripts in their own directories,
   matching the other suites? Or keep the current dispatcher model?

3. **Shared test utilities**: Should `test_common.sh` be used by all suites
   (currently only used by handler tests)?

4. **Pre-built binaries**: Should .cpp source files without build integration be
   removed (since they're just documentation), or should we add build instructions /
   Makefile targets?

5. **Skill or template**: What should the "new test suite" skill/template include?
   Suggested: directory skeleton, run_test.sh template, integration into
   run_all_tests.sh, output conventions.

6. **`.gitignore` placement**: Currently, pre-built test binaries are ignored via
   individual entries in the root `.gitignore`. Consider using per-suite
   `.gitignore` files instead (e.g., `tests/rocblas_filter/.gitignore`,
   `tests/hipblaslt/.gitignore`), so each suite manages its own ignored
   artifacts (binaries, build output, test output) locally.

### Expected Files
- All files under `tests/` — confirmed
- `run_all_tests.sh` — will need updates
- `.agents/kt/testing.md` — update after reorganization

### Risks
- Breaking existing CI or manual test workflows during migration
- Handler test sourced-subscript pattern may be harder to migrate than expected

## Plan of Record

### Micro-steps
Not yet planned. Requires design decisions (see above) before committing to steps.

## Progress Log

### Session 2026-03-06
- Created dossier from observation during hipBLASLt test development
- Surveyed all test suites and documented inconsistencies
- Status: TODO (design decisions needed before execution)

## Rejected Approaches
None yet.

## Open Questions
- See "Design Decisions Needed" above

## Last Verified
Commit: N/A
Date: 2026-03-06

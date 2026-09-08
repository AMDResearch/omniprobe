# Testing

## Purpose

Verifies correct behavior of message handlers and the full omniprobe instrumentation
pipeline. Currently uses end-to-end tests through the omniprobe CLI; unit tests with
GoogleTest are planned but disabled.

## Current Truth

**Test runner:** `tests/run_handler_tests.sh` (modular structure with subscripts).

**Tests:** 25 handler tests (6 basic, 6 block filter, 3 library filter, 7 scope filter, 3 module-load).

**Additional suites:**
- Library filter chain (5 tests)
- Triton (5 tests, requires `TRITON_DIR`)
- rocBLAS (5 tests, requires `INSTRUMENTED_ROCBLAS_LIB_DIR`)
- hipBLASLt (5 tests, requires `INSTRUMENTED_HIPBLASLT_LIB_DIR`)
- Combined rocBLAS+hipBLASLt

- Constant-memory visibility, `--no-filter` and `--with-matching-filter`
  (`tests/test_constant_memory_visibility.sh`, 2 suites)
- Kernel filter semantics, plain and `--assert-dwarf`
  (`tests/test_kernel_filter_semantics.sh`, 2 suites)

**Top-level runner:** `tests/run_all_tests.sh` (runs all 10 suites).

**The suite is green, and the tally depends entirely on the node.** Measured 2026-09-08 on
`k005-005.hpcfund` (MI210 / gfx90a) with `.untracked/test-env.sh` sourced: **10 run, 10 passed,
0 skipped, 0 failed**. On a gfx950 node with nothing sourced, the same command gives 6 run,
1 passed, 4 skipped, 1 failed. Neither the skips nor the failure are properties of the code —
see Negative Knowledge.

**Test helpers:**
- `run_test "test_name" "/path/to/kernel" "AnalyzerName" "expected pattern"`
- `run_filter_test "test_name" "/path/to/kernel" expected_count "x_filter" "y_filter" "z_filter"`
- `run_library_filter_test "test_name" "/path/to/kernel" '{"exclude":[...]}' "present|absent" "pattern"`

**GoogleTest:** Integration prepared but disabled (`INTERCEPTOR_BUILD_TESTING=OFF`).

**Test kernels** in `tests/test_kernels/`:
- `simple_heatmap_test.cpp`
- `simple_memory_analysis_test.cpp`
- `bank_conflict_test.cpp`
- `scope_filter_test.cpp`
- `module_load_kernel.hip` + `module_load_test.cpp`
- `hip_test_utils.h`

## Boundaries and Dependencies

- Working omniprobe installation.
- Instrumented test kernels.
- ROCm/HIP runtime.
- Available GPU device (device 0).

## Anchors / References

- `tests/run_all_tests.sh`
- `tests/run_handler_tests.sh`
- `tests/test_kernels/CMakeLists.txt`
- `.untracked/test-env.sh` — gitignored, and the only place `TRITON_DIR` /
  `INSTRUMENTED_ROCBLAS_LIB_DIR` / `INSTRUMENTED_HIPBLASLT_LIB_DIR` are defined. It exports the
  two instrumented-library paths **only when the node's architecture matches** what those
  libraries were built for (gfx90a); elsewhere they stay unset and the three dependent suites skip
  honestly rather than failing with `not ISA compatible with this GPU`. `source` it — the paths
  are personal and this repository is public, so they must not be copied into a tracked file.

## Negative Knowledge

- **Do NOT attempt to use GoogleTest** until handler refactoring for dependency injection is complete.
- Test kernels **MUST** be compiled with `-g` (debug info). Without it, DWARF source location info is missing, causing `MemoryAnalysis` handler to silently drop all messages.
- Test kernels should read back results (`hipMemcpy` to host) to prevent dead-store elimination.
- **A test binary built for the wrong GPU architecture does not error — it silently fails to
  dispatch, exits 0, and produces no reports.** `build/` is a gfx90a tree. Running it on a gfx950
  node made the Handler suite fail on `Expected pattern not found: 'memory heatmap report'`, and
  that failure was recorded as a pre-existing code defect for months. It is not one; the suite
  passes on matching hardware. The same artefact produced a second phantom defect, "rocBLAS
  integration test broken — instrumented `sscal` not found". **Check `rocminfo` against
  `CMAKE_HIP_ARCHITECTURES` before believing any test result.**
- **A suite tally measured where most suites skip records the environment, not the code.** Four of
  six suites skipping is not a weaker version of a green run; it is a different measurement. Both
  corrections above were invisible until the suite was run somewhere every suite could execute.
- **`tests/run_all_tests.sh:59` classifies a whole suite as skipped if the string `SKIP` appears
  anywhere in its output**, and `tests/rocblas_hipblaslt/run_test.sh:220` emits one mid-run. Latent
  — it has not fired, because the Tensile search at `run_test.sh:86` matches on filename glob plus
  a `__amd_crk_Cijk` symbol check rather than on architecture — but it would fire on a build
  without instrumented Tensile kernels.
- **`tests/triton/run_test.sh` exits 0 when it skips.** Any check reading only its exit status
  records a pass for a suite that never ran.
- **Renaming a log line silently re-points every test assertion written against it, and the
  absence checks fail silently.** When `Adding ` became `Indexing ` for application-loaded files,
  `tests/run_library_filter_tests.sh` failed loudly (a presence check) while
  `tests/library_filter_chain/run_test.sh`'s exclusion check — which proved a filter worked by
  asserting `Adding <lib>` was *absent* — kept passing and could no longer fail at all. Grep the
  tests in both directions when changing a log string. Both now match `^(Adding|Indexing) `; the
  `libdynamic_*` presence checks deliberately still match `Adding` alone, because those libraries
  arrive through a `--library-filter` include and are not mapped at startup.

## Open Questions

- What refactoring is needed to enable true unit tests with GoogleTest?
- Should we create a test fixture library for handler testing?

## Last Verified

- 2026-04-27 (removed transient bug/workflow references per pm-reflect)
- 2026-08-25 — the 25-test claim in Current Truth re-counted against the scripts and **held
  exactly**: basic 6, block_filter 6, library_filter 3, scope_filter 7, module_load 3. Counted from
  each suite's own runner, which differs per file (`run_test`, `run_filter_test`,
  `run_library_filter_test`, `run_scope_test`, and inline `TEST_NAME=` blocks in `module_load`
  with no runner function at all). **A single grep idiom undercounts this suite** — three
  successive attempts reported 6, then 22, before the fourth was right.
- 2026-09-08 — suite count 6 → 10 (`bf_hip-duplicate-code-object-load` adds four), green tally
  recorded on gfx90a, and four negative-knowledge entries added covering wrong-architecture
  binaries, skip-dominated tallies, the `SKIP`-anywhere classifier, and log-line renames breaking
  absence assertions. The two "pre-existing defects" this unit's environment had implied are
  retracted.

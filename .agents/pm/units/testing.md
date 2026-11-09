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
*(Superseded 2026-11-08: **18 suites**. Added since: 11 exit status, 12 output integrity,
13 build-tree bitcode (incl. missing-bitcode and two-file RDC link), 14 BBA robustness, 15 BBA
counts (`bb_counts_test`, analytic expected counts), 16 internal-linkage + zero-param kernels,
17 Python API end-to-end, 18 two-file non-RDC application.)*
*(Superseded again 2026-11-08, second session: **24 suites**, all GPU-dispatching. Each new suite
fails on the code before its fix:*
- *19 PythonHandler (`test_python_handler.sh`, fixtures in `tests/python_handler/`, kernel
  `python_handler_test.cpp`): exact per-dispatch message and distinct-address counts over 32
  dispatches on 4 streams; a large-message run with a device barrier that forces concurrent
  delivery (asserts >= 2 overlapping delivery intervals); one interpreter across dispatches;
  per-wave `handleAddressWave` fields incl. partial exec; `handleTimeMessage` fields.*
- *20 faulted dispatch (`fault_test.cpp`): a GPU-faulting kernel ends the run within 30 s with
  the app's status (3) and a warning naming the kernel, timing and `-i` modes; `--no-fault` run
  has no abandonment warning.* **It really faults the GPU: on a shared node other processes
  then fault too. Leave it out of full-suite runs there (supervisor rule, 2026-11-09).**
- *21 flat-pointer accesses (`flat_access_test.cpp` at `-O0` and `-O2`): same MemoryAnalysis
  findings; mixed-space wave stays unanalyzed.*
- *22 BBInterval loop (`bb_interval_loop_test.cpp`): 10 and 1000 iterations exit 0 with real
  intervals; >= 30 ticks per loop iteration (pinning).*
- *23 robustness: nonexistent `.so`, `.so` without `getMessageHandlers`, unknown analyzer,
  unusable PythonHandler module → exit 1 with an error; no ROCm for kernelDB → no dropped
  dispatches; exit summary in one piece under concurrent runs.*
- *24 kernel filter names (`kernel_filter_names_test.cpp`): `-k` regex semantics on plain,
  template, `.intern`, no-parameter, anonymous-namespace kernels; the no-match warning.)*

**Instrumented test kernels depend on the instrumentation plugin files** (`OBJECT_DEPENDS` in
`tests/test_kernels/CMakeLists.txt`, `ad19235`). `add_dependencies` only ordered the build, so a
rebuilt plugin left instrumented test binaries stale and the suites silently tested the previous
plugin. Any new instrumented kernel source in that directory is covered by the glob.

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
  *(2026-11-08: no longer silent — such accesses are counted in `unattributed_accesses` with a stderr line; see `memory-analysis`. `-g` is still required for attribution.)*
- Test kernels should read back results (`hipMemcpy` to host) to prevent dead-store elimination.
- **A test binary built for the wrong GPU architecture does not error.** *(Mechanism corrected
  2026-10-26 — this bullet used to say it "silently fails to dispatch, exits 0, and produces no
  reports". The exit 0 was not the architecture mismatch; it was
  `bf_exit-status-not-propagated`. Measured directly on gfx950,
  `build/tests/test_kernels/simple_heatmap_test` **dies of SIGSEGV and exits 139**. The silence
  only ever appeared when the binary was observed through `omniprobe`, which discarded the
  child's status. That is fixed as of `c5aec00`, so this failure mode is now loud — but the
  conclusions below are unaffected, since they were about the defects not existing.)*
  `build/` is a gfx90a tree. Running it on a gfx950
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
  *(Fixed 2026-11-08, `2419835`: a suite is classified skipped only on a line-start `SKIP:`,
  colour codes stripped.)*
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

- **`fuseblk` does not by itself mean "relocate the build to `/tmp`".** The machine-level
  filesystem notes flag `virtiofs` and `fuseblk` as lacking mmap support, breaking
  `hipModuleLoad` under ROCm 7.2, with building to `/tmp` as the workaround. Measured 2026-10-26
  on `k006-004-v3.hpcfund`, a KVM VM whose `/work1` and `/home1` are both `fuseblk`: **all eleven
  suites passed straight from the in-repo build tree**, GPU-dispatching ones included, with no
  relocation. The hazard is real but not universal and which operations trip it is
  uncharacterised. Treat the workaround as a response to an observed failure, not a
  precondition — and do not read one green run as evidence the hazard is gone either.
- **A full green run is 11 suites, and `Suites skipped: 0` requires gfx90a specifically.**
  `INSTRUMENTED_ROCBLAS_LIB_DIR` and `INSTRUMENTED_HIPBLASLT_LIB_DIR` point at gfx90a-only
  Tensile libraries; `.untracked/test-env.sh` withholds them on any other architecture and the
  three dependent suites then skip. Confirm `source .untracked/test-env.sh` prints **both**
  variables before trusting a tally. This constraint blocked `bf_exit-status-not-propagated`'s
  AC-8 for seven weeks.

- **Test scripts sourced under `set -e` must capture expected failures as
  `cmd && rc=0 || rc=$?`** — a bare failing command kills the sourcing runner (Triton suite).
- The library filter chain suite now uses `OMNIPROBE_ROOT`'s plugin and **fails, not skips**, on
  missing pieces (`bf_library-filter-chain-silent-pass`, done). The "§ Testing a tree other than
  `<repo>/build`" bullet about it below is superseded.
- Every bug fix of 2026-11-08 has a check shown to fail on the unfixed build; keep that standard.

## Acceptance-gate patterns that do not work here

Three collisions found by running checks against input that should fail them (2026-09-08). All
three read correctly in isolation; the defect is in the relationship between the pattern and the
files searched.

- **Never identify a new suite by grepping `tests/run_all_tests.sh` for the test's own path
  components.** `tests` matches `run_handler_tests.sh` and `run_test.sh` already appears five
  times, so the check passes against an **untouched** runner. Require the
  `Suite <n>: <name>` banner (printed at `tests/run_all_tests.sh:40`) in a real run instead — a
  file that never runs cannot produce one.
- **Never assert a guard exists by grepping the test script's source.** A comment satisfies it.
  Drive the guard — give the test a forcing environment variable and require a non-zero exit.
- **Never assert a string is *absent* from a test script.** It false-FAILs the moment the test
  documents why that string must not be asserted on, and the better-documented the test, the
  likelier it fires. Assert the presence of the right thing.

Also: `tests/run_all_tests.sh:59` marks a whole suite *skipped* if `SKIP` appears anywhere in its
output — so any criterion demanding `Suites skipped: 0` is sensitive to a new test's wording.

## Testing a tree other than `<repo>/build` (2026-10-27)

Needed whenever a change is tested from a worktree, or against a second build (another Triton,
an install tree). Four traps, each hit in one session:

- **Not every suite honours the overrides.** `tests/test_common.sh:10,14` honours `BUILD_DIR` and
  `OMNIPROBE_ROOT`. `tests/triton/run_test.sh` honours both since `f48753c` (2026-11-08; it
  used to hardcode `BUILD_DIR`, so a scratch-tree run tested `build/`'s plugin). `tests/library_filter_chain/run_test.sh` takes its instrumentation
  plugin from `../../build` (line 91) and gates Tests 2–5 on `${REPO_ROOT}/build` existing
  (line 155), ignoring both; if `build/` is missing it builds uninstrumented, skips four tests and
  **still reports PASSED**. Packet: `bf_library-filter-chain-silent-pass`. Until fixed, a
  worktree needs a `build -> <tree under test>` symlink.
- **The rocBLAS/hipBLASLt driver binaries are pre-built and gitignored** (`tests/hipblaslt/
  test_hipblaslt_transform`, `tests/rocblas_filter/test_rocblas_{scal,gemm}`). A fresh checkout
  fails three suites with `not found`. They link only ROCm's libraries, no omniprobe code, so
  copying them from the main checkout does not change what is tested.
  Rebuilding them is one hipcc line each (measured 2026-11-08, all three suites then pass):
  `hipcc --offload-arch=<arch> -Wl,-rpath,$ROCM/lib -L$ROCM/lib -o <bin> <bin>.cpp -l{hipblaslt|rocblas}`.
  The main checkout's `test_rocblas_{scal,gemm}` were built with ROCm 7.1.0 (RUNPATH
  `/opt/rocm-7.1.0/lib`); they still pass on 7.2.0, but a rebuild is the cleaner baseline.
- **The local test-env script prepends the main repo's `build/` to `LD_LIBRARY_PATH`.** Every
  omniprobe library has the same soname in every tree, so testing another tree with it left on
  the path can load the main tree's libraries and pass. Strip it, and check the `Plugin:` line in
  the output names the tree you meant.
- **`LD_LIBRARY_PATH` beats `RUNPATH`, and LLVM dev builds share sonames** — see `build-system`.

A test worth trusting checks that it ran, not only that it did not fail: grep for the
degradation warnings (`not found at`, `skipping omniprobe tests`, `Building without
instrumentation`) as well as the tally. And an acceptance check must be run against the
*unfixed* code once — `bf_library-filter-chain-silent-pass`'s AC-4 passed before its fix in the
first draft, because the condition it checked was gated off.

## Added 2026-11-08 (third session): suites 25-27 and hardware-specific notes

- Suite 25 bitcode selection (compile-only), 26 LDS vs `SQ_LDS_BANK_CONFLICT` (needs rocprofv3; 78 kernels; run under `flock -x
  /tmp/gpu-measure.lock`),
  27 `-d random` (replaced 2026-11-09 by dispatch selection). Full suite = **27 suites**. `tests/lds_conflict_sets/run.sh` (~15 s) is a tool,
  not a suite.
- gfx950 (MI350 VM, 1 GPU, fuseblk /work1): the full suite runs from an in-repo build tree; 24
  pass, rocBLAS/hipBLASLt suites skip (gfx90a-only libraries; record as N/A). The runtime kills
  `fault_test` with SIGPIPE (141) there; suite "Faulted dispatch" now expects the bare app's status.
- A clean parallel build needs every test target ordered after all three -rocm plugins (`1ec32b4`).
- A second worktree lacks the gitignored prebuilt `tests/hipblaslt/test_hipblaslt_transform` and
  `tests/rocblas_filter/test_rocblas_{gemm,scal}`: copy them or those suites fail.
- `tests/library_filter_chain/build` is reused unless the plugin path changes; clear it when the
  same path now points at another architecture's build.
- rocprofv3 leaves `.rocprofv3/` in its cwd; run it from an output directory.

## Open Questions

- What refactoring is needed to enable true unit tests with GoogleTest?
- Should we create a test fixture library for handler testing?

## Related Workflows

Workflows whose write scope reaches into `tests/`. State (= directory under `.agents/workflows/`) in parentheses.

- `bf_intern-clone-name` (done 2026-11-08, suite 16).
- `bf_pyhandler-gil` (active) — new suite `tests/test_python_handler.sh`; appends to `run_all_tests.sh`.
- `bf_library-filter-chain-silent-pass` (done 2026-11-08) — `tests/library_filter_chain/run_test.sh` only.
- `rf_test-organization` (suspended) — all of `tests/`; restructures suites, collides with everything above.
- `rf_exact-arch-bitcode` (suspended) — `tests/test_kernels/CMakeLists.txt`.
- `rf_rename-logduration-to-omniprobe` (suspended) — `tests/CMakeLists.txt`.
- Done, for history: `bf_exit-status-not-propagated` (suite 11), `bf_hip-duplicate-code-object-load`
  (suites 7–10), `ft_omniprobe-python-api`.

## Added 2026-11-09: suites 27-28, gfx950 build notes

- Suite 27 is now **Dispatch selection** (`test_dispatch_selection.sh`, parser table + GPU checks),
  suite 28 **PythonHandler in a Python host** (`test_python_host.sh`; needs TRITON_DIR, python3.9
  and python3.12). Full suite = **28 suites**; on gfx950 25 pass, 3 N/A.
- `build/` was reconfigured in place for gfx950 (`-DCMAKE_HIP_ARCHITECTURES=gfx950`); switch back
  on an MI210 node. A `tests/library_filter_chain/build` from another arch segfaults even without
  omniprobe — delete it when switching (suite 2 rebuilds it).
- Suite 26 reads hardware counters: run the full suite under `flock /tmp/gpu-measure.lock` on a
  shared node (~5 min on gfx950).

`tests/run_all_tests.sh` is shared and append-only: each packet adds its own `run_suite` line and edits no other.

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
2026-09-08 (acceptance-gate pattern collisions; each demonstrated against failing input)
2026-10-26 (11-suite green run on gfx90a; fuseblk finding; wrong-arch bullet mechanism corrected)
2026-10-27 (11/11 on Triton v3.8.0, default env; testing-another-tree traps; library_filter_chain silent pass)
2026-11-08 (18 suites; SKIP classifier fixed; library filter chain fails rather than skips; set -e lesson; full-suite tally not re-recorded in this unit)
2026-11-08 (second session: 24 suites, what suites 19-24 pin, OBJECT_DEPENDS on plugins, Triton suite BUILD_DIR; verified against tests/run_all_tests.sh, tests/test_kernels/CMakeLists.txt and commits ad19235/f48753c at 22c4d95; per-node tallies above not re-measured)
- 2026-11-08 (third session): suites 25-27 section.
- 2026-11-08 (fourth session): final main `113d53b` on gfx90a (MI210 VM, 1 GPU, fuseblk), fresh clone
  built in /tmp: 27/27 suites (3-5 after rebuilding the three driver binaries) + module-load 3/3.

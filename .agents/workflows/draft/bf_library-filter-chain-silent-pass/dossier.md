# Dossier — bf_library-filter-chain-silent-pass

## Metadata

- Workflow ID: bf_library-filter-chain-silent-pass
- Workflow Type: bugfix
- Lifecycle State: draft
- Owner / Current Executor: unassigned
- Intended Write Scope:
- Dependencies On Other Active Workflows: nominal write-scope overlap with `bf_intern-clone-name`
  and `bf_pyhandler-gil`, which both declare all of `tests/`. Neither touches this file in its
  plan. Do not execute concurrently with either; any order is fine.
- Base Commit: (unstamped — set at promotion)

```write-scope
tests/library_filter_chain/run_test.sh
```

## Objective

`tests/library_filter_chain/run_test.sh` must never report PASSED without having run its
omniprobe tests (Tests 2–5) against the omniprobe tree it was told to test. Concretely:

1. It instruments its test libraries with the plugin from the tree under test
   (`OMNIPROBE_ROOT`), not unconditionally from `${REPO_ROOT}/build`.
2. When no usable omniprobe tree exists, it **fails**, rather than warning and passing.
3. A run in which the static-library kernels were not instrumented cannot pass Test 2.

## Background / Context

Found 2026-10-27 while testing PR #44 from a fresh `git worktree` (no `build/`), with
`OMNIPROBE_ROOT` and `BUILD_DIR` pointing at a valid build elsewhere. The suite printed:

```
[WARN] Instrumentation plugin not found at: <worktree>/tests/library_filter_chain/../../build/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so
[WARN] Building without instrumentation. Run omniprobe build first for instrumented builds.
[INFO] Test 1 PASSED: App runs successfully without omniprobe
[WARN] omniprobe build directory not found at <worktree>/build - skipping omniprobe tests
[INFO] === All tests passed ===
Suite PASSED: Library filter chain
```

Four of its five tests did not run, and `run_all_tests.sh` counted the suite as passed.

**Three independent silent-pass paths**, line numbers at `913ae31`..`b12d7f0` (the file was not
touched by those commits):

| line | code | effect |
|---|---|---|
| 91 | `OMNIPROBE_BUILD="${SCRIPT_DIR}/../../build"` | plugin used to instrument the test libraries ignores `OMNIPROBE_ROOT`. If `build/` is absent: libraries built **uninstrumented**, warn only. If `build/` exists but `OMNIPROBE_ROOT` points elsewhere: libraries instrumented with a **different tree's** plugin than the omniprobe under test — silently mixed |
| 155 | `if [ ! -d "$OMNIPROBE_BUILD_DIR" ]` (`= ${REPO_ROOT}/build`, line 26) | gate on Tests 2–5 checks `build/` exists even when `OMNIPROBE_ROOT` is set — so install-tree / relocated-tree runs (the `cleanroom-test` skill's purpose) skip Tests 2–5 whenever `build/` is absent. Warn only, then `All tests passed` |
| 150 | `if [ ! -x "$OMNIPROBE" ]` | same: warn and skip Tests 2–5 |
| 171 | `log_warn "  Static library kernels: NOT INSTRUMENTED (unexpected)"` | Test 2 still prints PASSED when its own instrumentation assertion fails |

Tests 3–5 live inside the same `else` branch (lines 158–334), so paths at 150/155 skip four
tests at once.

**Why this matters beyond the one suite.** It is the same family as the log-line-rename hazard
and the suite-classifier risk in `current-focus.md`: an assertion that cannot fire. It also
silently undermined the PR #44 test it was found during — had #44 been tested from the main
repo, this suite would have instrumented with the *unpatched* `build/` plugin while omniprobe
ran from the patched tree, and still passed.

**Measured, not assumed:** in today's green runs on the main repo (default env, Triton 3.8.0,
gfx90a) Test 2 logs `Static library kernels: INSTRUMENTED`, so making line 171 fatal does not
break a correctly configured run. The test directory is self-contained (its `CMakeLists.txt`
has no `../` references), which gives a clean reproduction: copy `tests/library_filter_chain/`
under a scratch root that has no `build/`.

**Reproduction:**

```sh
S=$(mktemp -d); mkdir -p $S/tests
cp -r tests/library_filter_chain $S/tests/ && rm -rf $S/tests/library_filter_chain/{build,test_output}
source .untracked/test-env.sh
OMNIPROBE_ROOT=$PWD/build bash $S/tests/library_filter_chain/run_test.sh   # exit 0, Tests 2-5 skipped
```

## Contract

- The fix stays in `run_test.sh`. No change to the test libraries, the app, or `CMakeLists.txt`.
- Behaviour of a correctly configured default run (main repo, `build/` present, no
  `OMNIPROBE_ROOT`) is unchanged: same tests, same pass.
- Failure messages must not contain the substring `SKIP`: `tests/run_all_tests.sh:59`
  classifies a whole suite as *skipped* if that string appears anywhere in its output, which
  would turn the new loud failure back into a quiet non-pass.

## Acceptance Criteria

All run on a gfx90a node with `.untracked/test-env.sh` sourced and the main repo's `build/`
built. `S` denotes a scratch root containing only a copy of `tests/library_filter_chain/`.

- **AC-1**: With no `${S}/build` and `OMNIPROBE_ROOT=<repo>/build`, `run_test.sh` from `S`
  exits 0, prints `Test 5 PASSED`, and prints neither `skipping omniprobe tests` nor
  `Building without instrumentation`.
- **AC-2**: In the AC-1 run, `INST_PLUGIN` recorded in the test build's `CMakeCache.txt` is
  `<repo>/build/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so` — i.e. taken from
  `OMNIPROBE_ROOT`, not from `${S}/build`.
- **AC-3**: With no `${S}/build` and `OMNIPROBE_ROOT` pointing at a nonexistent directory,
  `run_test.sh` from `S` exits non-zero, does not print `Test 2 PASSED`, and its output does not
  contain the substring `SKIP`.
- **AC-4**: With `--no-instrument` (test libraries built without the plugin, so the static
  kernels are certainly not instrumented), run from a scratch root whose `build/` is a symlink
  to `<repo>/build` so that Test 2 is not gated off, `run_test.sh` does not print
  `Test 2 PASSED`. (Without the symlink the check is vacuous: Test 2 is skipped, so it
  "does not pass" before the fix too. The first draft of this check made that mistake.)
- **AC-5**: Default full suite from the main repo (`source .untracked/test-env.sh;
  tests/run_all_tests.sh`): 11 run, 11 passed, 0 skipped, 0 failed.
- **SCOPE**: no writes outside the `write-scope` block.

The AC-1/3/4 checks are the regression test. They live in `acceptance.sh`, which stays
re-runnable after the packet is archived; a separate in-repo meta-test of the test harness is
not added (see Non-Goals).

## Failure Policy

`stop`. If the fix cannot satisfy AC-5 without changing what a correctly configured run tests,
stop and report rather than loosening an assertion.

## Scope

The three silent-pass paths listed in Background, in `run_test.sh` only.

## Non-Goals

- Test 5's `libdynamic_mid/tail.so: NOT ADDED (getElfDependencies not implemented yet)` warnings.
  They describe a known feature gap, not a harness defect. (They did not appear in today's runs.)
- The `set -e` interaction at lines 159–164: under `set -e` a failing omniprobe run exits the
  script before `OMNIPROBE_EXIT=$?` is read, so the `Test N FAILED` branches are unreachable. That
  fails *loudly* (non-zero exit), just without its message. Record it; fix only if trivial and
  done in the same edit, without widening scope.
- The same hardcoded-`build/` pattern in other suites. Grep for it and list hits in
  `artifacts.md`, but fix them in their own packet.
- Making the driver binaries for the rocBLAS/hipBLASLt suites buildable from a fresh checkout
  (they are pre-built, gitignored, and absent in a new worktree). Separate issue.
- An in-repo meta-test of the harness.

## Constraints and Assumptions

- Needs a GPU (Tests 2–5 dispatch kernels) and an arch-matched build. gfx90a is the reference.
- `OMNIPROBE_ROOT`, when set, means "the tree under test"; when unset, `${REPO_ROOT}/build`
  (current default, line 27).

## Dependencies

None functional. See the write-scope note in Metadata.

## Plan Of Record

0. Promote: stamp `Base Commit` with `git rev-parse HEAD` and commit that alone.
1. **Reproduce** with the Background recipe: exit 0, Tests 2–5 skipped. Record in `run-log.md`.
2. **Diagnose**: confirm the three paths at lines 91, 150/155, 171 against the current file
   (line numbers may have shifted).
3. **Fix**: derive the plugin path and the Tests 2–5 gate from `OMNIPROBE_ROOT`; turn the
   missing-tree warnings and the line-171 warning into failures (`log_error` + `exit 1`), keeping
   `--no-instrument` behaviour coherent with AC-4. No message containing `SKIP`.
4. **Regression**: run `acceptance.sh` — AC-1..AC-4 exercise each path.
5. **Verify**: AC-5, full default suite.

## Verification Strategy

| criterion | check |
|---|---|
| AC-1 | scratch-root run, exit code + output greps |
| AC-2 | `grep ^INST_PLUGIN:` in the scratch build's `CMakeCache.txt`, compared to the expected path |
| AC-3 | scratch-root run with bogus `OMNIPROBE_ROOT`, exit code + output greps |
| AC-4 | `--no-instrument` run, absence of `Test 2 PASSED` |
| AC-5 | `run_all_tests.sh` summary parsed for the four counts |
| SCOPE | `ac_check_write_scope` |

AC-1/3/4 grep log text. That is acceptable here because the strings are the script's own
verdict lines, i.e. exactly what `run_all_tests.sh` and a human act on — but an edit that
renames those lines would turn the checks vacuous. If the fix changes any of `Test 2 PASSED`,
`Test 5 PASSED`, `skipping omniprobe tests` or `Building without instrumentation`, update
`acceptance.sh` in the same change.

## References

- Session 2026-10-27 logs: `.untracked/pr44-suite-t380-2026-10-27.log` (first, 8/11 run shows
  the silent pass alongside three missing-driver failures).
- `current-focus.md` § Project-Level Risks — log-line-rename and suite-classifier hazards.
- `tests/test_common.sh:10,14` — how the other suites honour `BUILD_DIR` / `OMNIPROBE_ROOT`.

## Open Questions

- With `--no-instrument`, should Tests 2–5 be skipped explicitly (exit 0, clear message without
  `SKIP`) or fail? AC-4 only requires that Test 2 cannot *pass*; either satisfies it. Owner's call
  at execution time; default to explicit skip-with-message, since the flag requests it.

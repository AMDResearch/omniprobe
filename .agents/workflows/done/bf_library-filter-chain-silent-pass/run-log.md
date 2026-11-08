# Run-Log

Append an entry after every meaningful execution step.

## Log Entries

### 2026-10-27 — packet created

- **Actor**: claude
- **Planned step**: draft the packet; confirm the acceptance script reproduces the bug
- **Action taken**: wrote dossier, acceptance.sh, handoff; ran acceptance.sh against unfixed code
- **Result**: AC-1, AC-2, AC-3 FAIL (reproduction); AC-5, SCOPE PASS. AC-4 initially PASSED
  vacuously (Test 2 gated off by missing `build/`); check corrected with a `build/` symlink and
  re-run in isolation — now FAILs pre-fix, printing `NOT INSTRUMENTED (unexpected)` then
  `Test 2 PASSED`.
- **Files touched**: this packet only
- **Verification**: acceptance.sh run, gfx90a, Triton 3.8.0, HEAD b12d7f0
- **Criteria impact**: none met — reproduction established for AC-1..AC-4
- **Blocker / Risk**: none

### 2026-10-27 — scope widened to the suite classifier (draft, owner-approved)

- **Actor**: claude
- **Planned step**: apply the accepted 2026-10-27 batch-review proposal and fold the
  `tests/run_all_tests.sh:59` classifier into this packet
- **Action taken**: added `tests/run_all_tests.sh` to the write scope, Objective item 4, AC-6
  (stub-driven classifier cases), AC-7 (real Triton suite with `TRITON_DIR` unset), plan step 4,
  and an Open Question on partial skips. Added the AC-6/7 checks to `acceptance.sh`.
- **Result**: ran the AC-6/7 block alone against the unfixed tree: AC-6 FAIL (incidental
  `SKIP` gives counters `0 1 0`, expected `1 0 0`) and AC-7 PASS. Positive control: both PASS
  against a candidate classifier in a throwaway copy.
- **Files touched**: this packet only
- **Verification**: as above; AC-1..5 not re-run (they need a GPU and the full suite)
- **Criteria impact**: AC-6 reproduction established
- **Blocker / Risk**: none

### 2026-11-08 — promoted, reproduced, fixed, verified (opimpl, supervised run)

- Promoted (`da67b44`, Base Commit 631e086). acceptance.sh on the unfixed tree: AC-1..4 and
  AC-6 FAIL, AC-5/7/SCOPE PASS (suite count is now 13).
- Fix `2419835`: plugin from `OMNIPROBE_ROOT`; missing plugin / missing omniprobe / uninstrumented
  static kernels are `log_error` + exit 1; `--no-instrument` prints "Tests 2-5 not run" and exits 0
  (open question 1: took the dossier default). The `OMNIPROBE_BUILD_DIR` gate is gone (the
  `$OMNIPROBE` check covers it).
- Classifier: skipped only on a line-start `SKIP:` notice after stripping colour codes.
  Open question 2 (partial skips): **not** taken to the default. Partial skips printed in the
  same `SKIP:` form (e.g. `rocblas_hipblaslt/run_test.sh:220`, the sourced handler sub-suites)
  are indistinguishable by form from whole-suite skips, so such a suite is still classified
  *skipped* — the conservative direction (never counted as a pass). Making partial skips
  visible separately needs an explicit marker convention; left for `rf_test-organization`.
- acceptance.sh after the fix: all PASS (below). Full suite 13/13.

```
PASS  AC-1     Tests 2-5 ran against OMNIPROBE_ROOT with no build/ in the repo root
PASS  AC-2     test libraries instrumented with the plugin from OMNIPROBE_ROOT
PASS  AC-3     missing omniprobe tree fails loudly (rc=1), no SKIP string
PASS  AC-4     with --no-instrument, Test 2 does not report PASSED (rc=0)
PASS  AC-6     classifier: incidental SKIP -> passed, whole-suite skip -> skipped, non-zero -> failed
PASS  AC-7     real Triton suite with TRITON_DIR unset is still classified skipped
PASS  AC-5     full suite: 13 run, 13 passed, 0 skipped, 0 failed
PASS  SCOPE    no writes outside the declared write scope (2 entries; working tree and commits since 631e0866ff8acef5695f3bf7e756739ef61d2a4b)
```

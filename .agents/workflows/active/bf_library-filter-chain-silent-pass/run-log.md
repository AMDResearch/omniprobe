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

# Handoff

**Location**: `.agents/workflows/draft/bf_library-filter-chain-silent-pass/handoff.md`

## Current Status

Draft, created 2026-10-27. Diagnosed, not fixed. No production edit made.

`acceptance.sh` has been run against the **unfixed** code (gfx90a, Triton 3.8.0,
`HEAD` = `b12d7f0`), and it reproduces the bug:

```
FAIL  AC-1   rc=0; Test 5 PASSED present: 0; skip/uninstrumented warnings: 2
FAIL  AC-2   INST_PLUGIN='<unset>', expected '<repo>/build/lib/plugins/...-rocm.so'
FAIL  AC-3   rc=0; ...                      <- exits 0 with a NONEXISTENT omniprobe tree
FAIL  AC-4   (after correcting the check, see below: NOT INSTRUMENTED (unexpected) -> Test 2 PASSED)
PASS  AC-5   full suite: 11 run, 11 passed, 0 skipped, 0 failed
PASS  SCOPE
```

AC-4 passed in the first run because its scratch root had no `build/`, so Test 2 was skipped
and "did not pass" vacuously — the same failure mode this packet is about. Fixed by giving the
AC-4 scratch root a `build/` symlink; re-checked in isolation and it now fails pre-fix as it must.

## Last Verified

2026-10-27, against `b12d7f0`.

## Next Exact Step

Plan of Record step 0: promote (move to `active/`, stamp `Base Commit`, commit alone). Then step
1 — run `acceptance.sh` once more to confirm the reproduction on the current tree before editing.

## Active Risks / Blockers

- Needs a GPU node with an arch-matched `<repo>/build`.
- Write-scope overlap is nominal: `bf_intern-clone-name` and `bf_pyhandler-gil` declare `tests/`.
  Do not run concurrently with either.
- `tests/run_all_tests.sh:59` treats any `SKIP` in a suite's output as "suite skipped". No new
  message may contain it (AC-3 checks).

## Required Reads Before Resuming

`dossier.md` (Background table and Contract). Nothing else.

## Proposed Spec Changes

## Scope Amendments

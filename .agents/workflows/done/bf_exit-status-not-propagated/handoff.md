# Handoff

**Location**: `.agents/workflows/active/bf_exit-status-not-propagated/handoff.md`

## Current Status

**Done. All acceptance criteria met.**
Base commit re-stamped to `24fcd82` (commit `cd62559`); fix in `c5aec00`.

AC-8, the last outstanding criterion, was met on 2026-10-26 once a gfx90a node was available.
No code changed between the 2026-09-08 gfx950 run and the closing run — the only difference was
the hardware.

## Last Verified

**2026-10-26, on `k006-004-v3.hpcfund` (gfx90a / MI210), ROCm 7.2.0**, against a freshly rebuilt
`build/` tree, with `.untracked/test-env.sh` sourced so both instrumented-library variables were
exported.

- `tests/run_all_tests.sh`: **Suites run 11, passed 11, skipped 0, failed 0**, exit 0.
  Full transcript at `.untracked/ac8-run-2026-10-26.log`.
- Gate result: **9 passed, 0 weak, 0 judgement, 0 failed — ACCEPTANCE PASSED.**

Worth recording: `/work1` and `/home1` on that node are **fuseblk**, which carries the known
mmap hazard that breaks `hipModuleLoad` under ROCm 7.2. It did not bite — the suite ran green
from the in-repo build tree with no relocation to `/tmp`. So fuseblk is not by itself
disqualifying for this suite, contrary to what the filesystem note would lead you to assume.

### Superseded: the 2026-09-08 measurement

2026-09-08, on `k007-005-v2.hpcfund` (**gfx950** / MI350X), against `build/` (a gfx90a tree —
irrelevant there, since every target in this packet is a `/bin/sh` stub).
Gate result after the fix: **7 passed, 0 weak, 0 judgement, 1 failed** — the failure was AC-8.

Measured by hand as well, exact numbers not "nonzero":

| target | before | after |
|---|---|---|
| `/bin/sh -c 'exit 42'` | 0 | **42** |
| `/bin/sh -c 'kill -SEGV $$'` | 0 | **139** |
| `/bin/true` | 0 | 0 |

## What Was Decided

All three of the dossier's questions were taken as recommended; the reasoning is in `run-log.md`
under *the three decisions*. In short: `128 + signal` via a named `shell_exit_status()` helper;
finalize JSON then exit; and a warning that says what happened to *the application* without
claiming the analysis failed.

**Open Question 1 is closed.** The Triton target exits **0** — measured directly, with a wrapper
that reports the target's own status, before any source change. `tests/triton/run_test.sh:89`
does gate on omniprobe's status and so was the place this could have bitten; it does not. No
report to the user was needed under the `stop` failure policy.

## One finding worth carrying forward

**AC-5 failed after the fix, and the cause was not ordering.** A `/bin/sh` target dispatches no
kernel, so the handler never creates the JSON file — and a **successful** `/bin/true` target
produced no file either. The gate was therefore observing "did any dispatch happen", not "was the
exit ordered after finalization", and *no* ordering could have satisfied it on a no-GPU target.

`finalize_json_output` now writes `[]` when JSON output to a file was requested and nothing was
written. That makes AC-5 true as stated *and* makes the gate a real ordering observable: exiting
before finalization would leave no file at all and still FAIL. The packet's no-GPU property,
which the dossier's Constraints ask for explicitly, is preserved.

## Next Exact Step

**N/A — workflow complete.**

## What was predicted about the gfx90a run, and what happened

The prediction below was written on 2026-09-08. It held: the three gfx90a-only library suites
passed on first run, and the handler suites passed 25/25 on matching hardware as expected.
Recorded unchanged because a prediction that held is worth as much as one that did not.

- **The handler suite passes 25/25 with this fix live**, measured against the arch-matched
  `build_gfx950/` tree on this node. Its failure in the gfx950 full run is the gfx90a-binary
  artifact, not status propagation — worth stating because the *failure mode changed* with this
  fix (`Kernel execution failed` is a `test_common.sh:run_test` branch that could never be taken
  while omniprobe always exited 0).
- Seven of eleven suites passed on this node with the fix live. Only the three gfx90a-only
  library suites have never been exercised against it.

**A correction that belongs in `current-focus.md`** (not written there — outside this packet's
write scope): that file records a gfx90a binary on gfx950 as failing "silently, producing exit 0
with no output". Measured: `build/tests/test_kernels/simple_heatmap_test` on gfx950 **dies of
SIGSEGV and exits 139**. The exit 0 *was this bug*, seen through omniprobe. Two phantom "known
defects" were already attributed to that misreading.

## Active Risks / Blockers

**None. The packet is complete.** The two notes below are retained because they outlive it:
the first as a standing property of the test environment, the second as a constraint on the two
sibling packets that still share `tests/run_all_tests.sh`.

- **AC-8 cannot be measured on a gfx950 node.** *(Resolved for this packet on 2026-10-26 by
  running on gfx90a; the constraint itself is unchanged and still applies to any future gate that
  demands `Suites skipped: 0`.)* `INSTRUMENTED_ROCBLAS_LIB_DIR` and
  `INSTRUMENTED_HIPBLASLT_LIB_DIR` are gfx90a-only, `.untracked/test-env.sh` deliberately
  withholds them elsewhere, and the three instrumented-library suites then print their own skip
  marker and are counted as skipped — so `Suites skipped: 0` is unreachable here. `acceptance.sh`
  says so in its own comment at the AC-7/AC-8 block. The handler suites additionally run gfx90a
  binaries, which on gfx950 do not error, they silently do not dispatch. **This is an environment
  constraint, not a defect in the fix**, and it is the same effect that manufactured two
  long-standing phantom "known defects" recorded in `current-focus.md`.
- **`tests/run_all_tests.sh` is shared with two other active packets.** This packet appended
  exactly one `run_suite` line (suite 11, "Exit status propagation") plus its comment and edited
  no other line. Keep it that way.
- The new suite prints nothing containing the whole-suite skip marker that
  `tests/run_all_tests.sh:59` greps for; a comment in the test says so. Do not add it.

## Required Reads Before Resuming

N/A — nothing to resume. For the record of what this packet established, read this file's
§ One finding worth carrying forward and § Last Verified.

## Proposed Spec Changes

None.

## Scope Amendments

None. All four declared paths were written and nothing outside them was.

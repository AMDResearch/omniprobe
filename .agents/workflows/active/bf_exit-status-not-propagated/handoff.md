# Handoff

**Location**: `.agents/workflows/active/bf_exit-status-not-propagated/handoff.md`

## Current Status

**Active. The fix is implemented, committed and verified; AC-1 through AC-7 are met.**
Base commit re-stamped to `24fcd82` (commit `cd62559`); fix in `c5aec00`.

**AC-8 is the only criterion outstanding, and it is blocked by hardware, not by the code.**
See § Active Risks below — it needs a gfx90a node.

Step 0 (re-stamp the base commit) is **done**. `SCOPE` is `PASS` and will stay there.

## Last Verified

2026-09-08, on `k007-005-v2.hpcfund` (**gfx950** / MI350X), ROCm 7.2.0, against `build/`
(a gfx90a tree — irrelevant here, since every target in this packet is a `/bin/sh` stub).

Gate result after the fix: **7 passed, 0 weak, 0 judgement, 1 failed** — the failure is AC-8.

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

**Run `tests/run_all_tests.sh` on a gfx90a node with `.untracked/test-env.sh` sourced, and
confirm `Suites failed: 0` and `Suites skipped: 0`.** That is AC-8 and it is all that remains.
Nothing else about the packet is open.

## What is already known about the gfx90a run

Do not assume the remaining step is a formality, but it is well-supported:

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

- **AC-8 cannot be measured on a gfx950 node.** `INSTRUMENTED_ROCBLAS_LIB_DIR` and
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

1. This file. `dossier.md` only if you need the contract text — the work is done and the
   remaining step is a single command.
2. `.agents/state/current-focus.md` § Project-Level Risks, for why the node's architecture
   decides whether AC-8 is measurable.

## Proposed Spec Changes

None.

## Scope Amendments

None. All four declared paths were written and nothing outside them was.

# Handoff: rf_exact-arch-bitcode

## Current Status
Active. gfx90a side done and committed (`0ed8fa4` merge of PR #38, `6acf90f` follow-up). Open:
AC-7 runtime results on gfx950, and the dh_comms gfx950 decision.

## Next Step
1. Supervisor decision on dh_comms gfx950 support (patch ready, see run-log). If approved: commit
   in the submodule, push to AMDResearch/dh_comms, bump the submodule pointer, add gfx950 to
   `IdentifiedByDhComms` (InstrumentationCommon.cpp) and `IDENTIFIED` (test_bitcode_selection.sh),
   flip test 4 to expect the exact file.
2. On an MI350 node: `bash .untracked/gfx950-validation/run.sh` (no build; prints which bitcode
   the gfx950 compile linked, runs all suites). Re-sync the worktree first if main moved:
   `git -C .untracked/wt-gfx950 checkout --detach <commit>` + incremental build on gfx90a.
3. PR #38 comment (draft awaits supervisor OK).

## Blockers
gfx950 hardware (supervisor switches the allocation after the other workers finish).

## Proposed Spec Changes
Recorded in the dossier ("Spec changes on resumption").

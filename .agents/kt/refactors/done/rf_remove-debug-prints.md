# Refactor: Remove Debug Prints

## Status
- [ ] TODO
- [ ] In Progress
- [ ] Blocked
- [x] Done

## Objective
Remove verbose debug prints from omniprobe and its sub-projects (dh_comms, kerneldb) that clutter runtime output.

## Refactor Contract

### Goal
Delete all `std::cerr`/`std::cout` debug statements that produce the `[X]`-marked lines in `tests/test_output/results.txt`.

### Non-Goals / Invariants
- ABI compatibility: n/a
- API compatibility: n/a
- Performance constraints: none
- Threading model: unchanged
- Other invariants:
  - Keep legitimate status messages ("Comms Runner shutting down", "signal_runner is shutting down", etc.)
  - Only remove the specific debug prints identified

### Verification Gates
- Build: `ninja` in build directory
- Runtime: Run `ROCR_VISIBLE_DEVICES=0 ~/work/.local/bin/logDuration/omniprobe -i -a MemoryAnalysis -- ~/repos/mem_analysis_dwordx4/dwordx4_inst` and verify `[X]`-marked lines from results.txt are gone

## Scope

### Affected Symbols
Debug print statements (std::cerr/std::cout) in:
- `comms_mgr` constructor/destructor and checkout/checkin methods
- `hsaInterceptor` destructor and signal completion
- `handlerManager` destructor
- `dh_comms` constructor/destructor/report
- `kernelDB` destructor

### Expected Files
- `src/interceptor.cc` — confirmed (~18 prints)
- `src/comms_mgr.cc` — confirmed (~10 prints)
- `src/utils.cc` — confirmed (~4 prints)
- `external/dh_comms/src/dh_comms.cpp` — confirmed (~6 prints)
- `external/kerneldb/src/kernelDB.cc` — confirmed (~1 print)

### Call Graph Impact
None — removing print statements only.

### Risks
- Risk 1: Accidentally removing a non-debug print — mitigated by checking each line against [X]-marked output
- Risk 2: Forgetting to commit in a submodule — mitigated by explicit steps per repo

## Plan of Record

### Micro-steps
1. [x] Remove debug prints from `src/interceptor.cc` — Gate: compile
2. [x] Remove debug prints from `src/comms_mgr.cc` — Gate: compile
3. [x] Remove debug prints from `src/utils.cc` — Gate: compile
4. [x] Remove debug prints from `external/dh_comms/src/dh_comms.cpp` — Gate: compile dh_comms
5. [x] ~~Remove debug print from `external/kerneldb/src/kernelDB.cc`~~ — Skipped (user correction: keep this print)
6. [x] Full rebuild and runtime verification — Gate: run omniprobe, verify [X] lines gone

### Current Step
Completed.

## Progress Log

### Session 2026-03-04
- Created refactor dossier
- Surveyed codebase, identified 5 files across 3 repos
- Established contract with user
- Removed debug prints from interceptor.cc, comms_mgr.cc, utils.cc, dh_comms.cpp
- User correction: "Ending kernelDB" should stay — restored it, no kerneldb changes
- Runtime verification passed — all [X] lines removed
- Commits pending in omniprobe (main repo) and dh_comms (submodule)

## Rejected Approaches
None yet.

## Open Questions
None.

## Last Verified
Commit: ce669e9 (main), 9b2a6a5 (dh_comms)
Date: 2026-03-04

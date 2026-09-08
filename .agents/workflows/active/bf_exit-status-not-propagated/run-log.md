# Run-Log

Append an entry after every meaningful execution step. This is not optional. If the session is
interrupted, this log is the only record of progress.

## Log Entries

### 2026-09-08 09:45

- **Actor**: claude
- **Planned step**: Turn the incoming seed into a packet, verifying its claims first rather than
  taking another agent's report at face value.
- **Action taken**: Committed the seed unedited, then re-checked every claim against this
  repository at `8de44b0`: the unread `process.returncode`, the comment at `:169` that announces
  a read it does not perform, the discarded call at `:823`, the JSON finalization at `:825`, the
  API's sole returncode check at `omniprobe/api/omniprobe.py:154` and its `"[]"` fallback at
  `:164`.
- **Result**: success. Every claim held exactly. Also found a constraint the seed did not mention:
  `capture_subprocess_output` has a **second caller** at `:225` (`rocminfo`, ISA detection), which
  makes "return a value" safe but "exit or raise from inside the function" unsafe. AC-6 was added
  to guard it.
- **Files touched**: packet files under `.agents/workflows/draft/bf_exit-status-not-propagated/`
- **Verification**: source reading only; the end-to-end measurement belongs to Plan Of Record
  step 1 and has not been repeated in this repository.
- **Criteria impact**: none met. All open by design at draft.
- **Blocker / Risk**: Open Question 1 (Triton path) is unmeasured.

### 2026-09-08 10:40

- **Actor**: claude
- **Planned step**: Readiness check, then promote.
- **Action taken**: Ran the checklist. All structural items passed. The step-3 pattern audit found
  two defects, both found by *running* the gate rather than reading it: AC-4 drove a module-level
  API that does not exist (the surface is a class, and `_run` splits the command on whitespace, so
  the crashing target must be a single-token script), and AC-6 asserted a `gfx` string that a HIP
  run never prints — a false FAIL for reasons unrelated to this packet. AC-6 was rewritten to
  drive the actual regression risk: a `sys.exit()` inside `capture_subprocess_output` would kill
  the interpreter during ISA detection at `omniprobe/omniprobe:225`.
- **Result**: READY. Promoted `draft` → `active`, base commit `821c89b`.
- **Files touched**: `acceptance.sh`, `dossier.md`, `handoff.md`, packet directory moved
- **Verification**: gate runs to completion. At the base commit it reproduces the defect and its
  downstream consequence: AC-1 and AC-2 report exit 0 for a target that exited 42 and one killed
  by SIGSEGV; AC-4 shows the API returning an empty result rather than raising. AC-3 and AC-6 pass
  — correct, they are the regression guards, and a gate whose guards fail before the work starts
  cannot tell a fix from a break.
- **Criteria impact**: none met; 3 of 8 pass as guards.
- **Blocker / Risk**: Open Question 1 (Triton path) still unmeasured.

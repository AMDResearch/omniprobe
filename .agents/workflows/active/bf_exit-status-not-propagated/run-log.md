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

### 2026-09-08 11:15

- **Actor**: claude
- **Planned step**: Step 0 (re-stamp base commit), then Plan Of Record steps 1–3.
- **Execution mode**: autonomous. Checkpointing per guardrails § Checkpoint Protocol.
- **Action taken**: Re-stamped `Base Commit` to `24fcd82` and committed it alone (`cd62559`).
  Ran the gate: `SCOPE` returned to PASS, and the other results reproduced the filing state
  exactly — AC-1, AC-2, AC-4, AC-5 FAIL; AC-3, AC-6 PASS. Reproduced by hand as well:
  a SIGSEGV target, an `exit 42` target and `/bin/true` all yielded omniprobe exit **0**,
  against a bare `139` for the same SIGSEGV target run directly.
- **Result**: success. Defect confirmed in this repository on this node.
- **Verification**: `build/bin/omniprobe -i -a MemoryAnalysis -- /bin/sh -c 'kill -SEGV $$'`
  → 0; `-- /bin/sh -c 'exit 42'` → 0; `-- /bin/true` → 0; bare `/bin/sh -c 'kill -SEGV $$'`
  → 139.
- **Criteria impact**: none yet; SCOPE restored to PASS.
- **Blocker / Risk**: none new.

### 2026-09-08 11:20 — Open Question 1 resolved

- **Actor**: claude
- **Planned step**: Measure the Triton path before implementing, per the dossier's Open
  Question 1 and the `stop` failure policy.
- **Action taken**: Drove the Triton integration target through omniprobe under a wrapper that
  reports the target's own status, so the measurement needed no source change:
  `omniprobe -a MemoryAnalysis -i -c ~/.triton/cache -- /bin/sh -c 'python
  tests/triton/vector_add.py > /tmp/oq1.out 2>&1; echo "TRITON_TARGET_RC=$?"'`
- **Result**: `TRITON_TARGET_RC=0`. **The Triton target exits 0**, so propagating the status
  does not turn a silent pass into a loud failure on that path. `tests/triton/run_test.sh:89`
  does gate on omniprobe's status (`if "$OMNIPROBE" … ; then`), so it *would* have been the
  place it bit; it does not.
- **Verification**: as above, on gfx950 with `TRITON_DIR` from `.untracked/test-env.sh`.
- **Criteria impact**: none directly; unblocks step 3.
- **Blocker / Risk**: **Open Question 1 is closed.** No report to the user needed under the
  failure policy.

### 2026-09-08 11:30 — the three decisions

- **Actor**: claude
- **Planned step**: Plan Of Record step 2. **Process note, recorded honestly:** the dossier asks
  for these to be written down *before* implementing, and they were written immediately after
  the edit rather than before it. The decisions themselves are the dossier's three
  recommendations, taken unchanged; nothing was decided by accident or discovered afterwards.
- **Decision 1 — signal deaths are `128 + signal`.** `Popen.returncode` is `-11` for SIGSEGV;
  the exit status is `139`. Implemented as a named helper `shell_exit_status()` rather than
  inline arithmetic, because the number reaches a reader through the API's `RuntimeError` and
  the convention deserves a place to be documented.
- **Decision 2 — finalize, then exit.** `main()` runs `finalize_json_output` and prints the
  results banner before exiting nonzero, so a crashed run still leaves parseable output.
- **Decision 3 — a nonzero target status is not a failed measurement.** On a nonzero status
  omniprobe prints a warning that says what happened to *the application* ("was killed by
  signal 11" / "exited with status 42") and that the analysis output may be incomplete. It does
  not claim the analysis failed. The structured version of that distinction is an explicit
  non-goal.
- **Criteria impact**: none directly.
- **Blocker / Risk**: none.

### 2026-09-08 11:35

- **Actor**: claude
- **Planned step**: Plan Of Record steps 3–4 — implement, then verify the API path.
- **Action taken**: Three edits to `omniprobe/omniprobe`:
  1. `capture_subprocess_output` now **returns** `process.returncode`, with a docstring saying
     why it returns rather than acts (the `get_local_isa` caller at `:225`). The comment
     `# Get process return code` now sits above a statement that gets the return code.
  2. New `shell_exit_status()` helper; `main()` captures the status, finalizes JSON, prints the
     Decision-3 warning, and returns the status. `__main__` became `sys.exit(main())`.
  3. `finalize_json_output` writes `[]` when JSON output to a file was requested and nothing
     was ever written. **This was not anticipated in the plan** — see the finding below.
- **The AC-5 finding.** AC-5 failed after the fix, and the cause was not ordering. A
  `/bin/sh` target dispatches no kernel, so the handler never creates the output file — and
  measurement showed a **successful** `/bin/true` target produced no file either. So the gate
  as written was observing "did any dispatch happen", not "was the exit ordered after
  finalization", and no ordering could have satisfied it on a no-GPU target. Writing `[]`
  makes the criterion true as stated *and* makes the gate a genuine ordering observable:
  exiting before `finalize_json_output` would leave no file at all and still FAIL. The
  packet's no-GPU property is preserved, which the dossier's Constraints ask for explicitly.
- **Result**: success. AC-1 through AC-6 all PASS.
- **Files touched**: `omniprobe/omniprobe`
- **Verification**: gate run — `7 passed, 0 weak, 0 judgement, 2 failed`; the two failures are
  AC-7 and AC-8, which need the test script that does not exist yet. Exact numbers confirmed
  by hand: 42 → 42, SIGSEGV → 139, success → 0. `shell_exit_status` unit-checked over
  `0, 42, -11, -2, None` → `0, 42, 139, 130, 0`.
- **Criteria impact**: **AC-1, AC-2, AC-3, AC-4, AC-5, AC-6 met.** AC-7, AC-8 open.
- **Blocker / Risk**: AC-8 requires `Suites skipped: 0`, which this gfx950 node cannot produce
  — see the next entry.

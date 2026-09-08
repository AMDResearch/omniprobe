# Dossier — bf_exit-status-not-propagated

## Metadata

- Workflow ID: bf_exit-status-not-propagated
- Workflow Type: bugfix
- Lifecycle State: draft
- Owner / Current Executor: unassigned
- Intended Write Scope: see the `write-scope` block below (canonical)
- Dependencies On Other Active Workflows: shares `tests/run_all_tests.sh` with
  `bf_intern-clone-name` and `bf_pyhandler-gil` — see § Dependencies for the coordination rule
- Base Commit: (unstamped — set at promotion)

```write-scope
omniprobe/omniprobe
omniprobe/api/omniprobe.py
tests/test_exit_status.sh
tests/run_all_tests.sh
```

## Objective

`omniprobe` exits with a status that reflects what happened to the instrumented target. A target
that exits nonzero is reported with that status; a target killed by a signal is reported as a
failure with a value a reader recognises; a successful run still exits 0.

The consumer-facing half matters as much as the CLI half: driving a crashing target through
`omniprobe/api/omniprobe.py` must raise `RuntimeError` rather than returning `"[]"`.

## Background / Context

Filed as a seed on 2026-09-08 by an agent working in the `intellikit` sidecar
(`.agents/workflows/seeds/bf_exit-status-not-propagated.md`). Every claim below was
**re-verified in this repository at `8de44b0`** before the packet was written; the seed was
accurate in every particular.

### The defect

`omniprobe/omniprobe`, `capture_subprocess_output()`. The function polls the child to completion
and then — under a comment that says it is about to read the status — does not:

    169:        # Get process return code
    170:        remaining = process.stdout.read()

`process.returncode` is populated by that point and never read. The function returns `None`
implicitly. `main()` discards even that (line 823), finalizes JSON output, and falls off the end,
so the interpreter exits 0. **There is no path by which a target's failure can reach the caller.**

`KeyboardInterrupt` is handled separately and does `sys.exit(1)`, so Ctrl-C is reported correctly.
Only ordinary child failure — including fatal signals — is swallowed.

### Why it is load-bearing

`omniprobe/api/omniprobe.py:154` has exactly one failure check, and it tests the value this bug
makes constant:

    154:            if result.returncode != 0:
    155:                raise RuntimeError(...)

The next lines degrade quietly on the same path — `output_path.exists()` fails and the function
returns `"[]"` (line 164). So a crashed run yields returncode 0, no exception, and an
empty-but-well-formed result that flows out to the caller as a successful analysis of nothing.

**The realistic failure is partial, not empty.** IntelliKit's integration tests assert
non-emptiness, so a wholly-empty result is caught. What is not caught is a run that crashes
*after* some dispatches: the result is non-empty, every assertion passes, and the data is silently
truncated. Any conclusion drawn from it — a coalescing ratio, a cycle distribution, a regression
comparison — is computed over a fraction of the kernels and looks entirely normal.

### Measured by the filing agent

MI350X (gfx950), ROCm 7.2.0, at `44547f9`, against
`build/tests/test_kernels/simple_memory_analysis_test` under a handler that segfaults on the
`dh_comms` worker thread:

| Invocation | Reported | Actual |
|---|---|---|
| `omniprobe -i -a <handler> -- <target>` | **exit 0** | target died of SIGSEGV |
| target run directly with the env from `omniprobe -e` | exit **139** | SIGSEGV (128+11) |

### Three decisions this fix has to make

The seed flagged all three rather than assuming them, and they are restated here because each
changes observable behaviour:

1. **Signal deaths are negative.** `Popen.returncode` is `-11` for SIGSEGV, not `139`. Shell
   convention is `128 + signal`. Whichever is chosen, the API's `RuntimeError` interpolates the
   number, so it must be one a reader recognises. **Recommendation: `128 + signal`** — it is what
   a shell reports and what AC-2 asserts.
2. **Ordering against `finalize_json_output`.** `main()` finalizes JSON after the run (line 825).
   Exiting before it leaves malformed JSON; exiting after runs the finalizer on partial data.
   **Recommendation: finalize, then exit**, so a crashed run still produces parseable output —
   and consider marking the result truncated in the JSON rather than closing it silently.
3. **A nonzero target status does not always mean the analysis failed.** A workload may exit
   nonzero for its own reasons while the measurement is complete and valid. Conflating the two
   would introduce the mirror-image bug. At minimum the message should distinguish them.

### Note for the implementer

`capture_subprocess_output` has a second caller: `capture_subprocess_output(["rocminfo"], ...)` at
line 225, used for ISA detection. Adding a return value is safe for it; making the function itself
exit or raise would not be. AC-6 guards this.

## Contract

Propagate the instrumented target's exit status through `omniprobe` to its caller, including
signal deaths, without changing the status of successful runs and without breaking the `rocminfo`
caller.

## Acceptance Criteria

- **AC-1**: A target that exits with a specific nonzero status is reported with **that** status.
  Asserted on the exact number (a stub exiting 42 yields 42), not merely on nonzero.
- **AC-2**: A target killed by `SIGSEGV` is reported as a failure with the value **139**
  (`128 + 11`). This is the case that motivated the seed and no other criterion covers it.
- **AC-3**: A target that succeeds still yields exit 0. The regression guard — it is what stops
  the fix being "always exit 1".
- **AC-4**: Driving a crashing target through `omniprobe/api/omniprobe.py` raises `RuntimeError`
  rather than returning `"[]"`. This is the criterion that shows the fix reaches the consumer that
  depends on it; a CLI-only test would pass without it.
- **AC-5**: On a failing run, JSON output is still finalized and parseable — the ordering decision
  above is made deliberately and is observable.
- **AC-6**: ISA detection still works: the `rocminfo` call at `omniprobe/omniprobe:225` is
  unaffected and `omniprobe` still resolves the GPU architecture on a normal run.
- **AC-7**: The new suite is registered in `tests/run_all_tests.sh` and runs as part of it.
- **AC-8**: `tests/run_all_tests.sh` reports every suite passed, 0 failed, 0 skipped.

## Failure Policy

`stop`. If propagating the status turns out to break a consumer in a way not anticipated here —
in particular the Triton path, which drives `omniprobe` differently — report rather than
suppressing the status again for that path.

## Scope

- `capture_subprocess_output` and `main()` in `omniprobe/omniprobe`.
- `omniprobe/api/omniprobe.py` only if AC-4 shows a change is needed there; the expectation is
  that its existing check starts working once the value stops being constant.
- A new test script and its registration.

## Non-Goals

- Distinguishing "the workload failed" from "the measurement failed" as a **structured** result
  (a separate field, a distinct exit range). Decision 3 above asks only that the message not
  conflate them. Anything richer is a design change and belongs in its own packet.
- Marking truncated analysis output as truncated in the JSON schema. Worth doing; not this.
- The `bf_pyhandler-gil` defect, which the filing session used as its crash source. The two are
  independent and this one reproduces with any target that dies of a signal.
- Changing `KeyboardInterrupt` handling, which already reports correctly.

## Constraints and Assumptions

- **No GPU is required to reproduce this.** A crashing target can be `/bin/sh -c 'kill -SEGV $$'`
  and a specific-status target `/bin/sh -c 'exit 42'`. That makes the whole packet testable on any
  node, which is unusual for this repository and should be preserved in the test design.
- A latent classifier bug in `tests/run_all_tests.sh:59` marks a whole suite *skipped* if the
  string `SKIP` appears anywhere in its output. The new test must not emit that string.
- Note this repository is public: the test must not embed personal absolute paths.

## Dependencies

None blocking.

**Shared-file coordination.** Three active packets append a `run_suite` line to
`tests/run_all_tests.sh`: this one, `bf_intern-clone-name`, and `bf_pyhandler-gil`. The file is
declared in all three write scopes deliberately. The coordination rule is: **each packet appends
only its own `run_suite` line and edits no other line.** Executed in separate sessions as
intended, that is append-only and conflict-free. Do not reformat or reorder the file.

## Plan Of Record

1. **Reproduce.** Run `omniprobe -i -a MemoryAnalysis -- /bin/sh -c 'kill -SEGV $$'` and confirm
   exit 0. Confirm the same for `exit 42`.
2. **Decide the three questions** in Background above and record the decisions in `run-log.md`.
3. **Implement**: return `process.returncode` from `capture_subprocess_output`; in `main()`,
   capture it, finalize JSON, then exit with the chosen convention.
4. **Verify the API path** (AC-4) — this is the one that proves the fix reaches the consumer.
5. **Add the regression test** covering AC-1 through AC-6.
6. **Verify**: new suite, then full `tests/run_all_tests.sh`.

## Verification Strategy

| Criterion | Check |
|---|---|
| AC-1 | run `omniprobe … -- /bin/sh -c 'exit 42'`; assert `$? == 42` |
| AC-2 | run `omniprobe … -- /bin/sh -c 'kill -SEGV $$'`; assert `$? == 139` |
| AC-3 | run `omniprobe … -- /bin/true`; assert `$? == 0` |
| AC-4 | drive `Omniprobe(...).analyze_memory(<crashing target>)`; assert `RuntimeError` raised and the result is not empty-but-well-formed |
| AC-5 | on a failing run with `-t json -o <file>`, assert the output file exists and parses |
| AC-6 | call `capture_subprocess_output` on a **failing** command through the `handler=`/`new_env=` call shape and assert the interpreter survives |
| AC-7 | **behavioural**: require a `Suite <n>: …exit status…` banner in the `run_all_tests.sh` output |
| AC-8 | `tests/run_all_tests.sh` exits 0 **and** the tally line reads `Suites skipped: 0` |

AC-1 through AC-3 assert **exact numbers** on purpose. "Nonzero" would be satisfied by a fix that
always exits 1, which would be a different bug wearing this one's clothes.

AC-7 is behavioural rather than a grep of `run_all_tests.sh`, because the obvious grep is a
vacuous PASS: a pattern built from the test's own path components matches the untouched file
(`tests` hits `run_handler_tests.sh`; `run_test.sh` already appears five times). Verified
2026-09-08 against the unmodified runner. Requiring the suite banner in a real run cannot be
satisfied by a file that never runs.

**AC-6's observable is deliberately not "a `gfx` string appears somewhere".** The first draft of
this gate asserted that, and it false-FAILed: `get_local_isa()` is consulted only on the Triton
path, its architecture list stops at `gfx942`, and a HIP run never prints it — verified
2026-09-08, `-e` on a HIP run emits `LOGDUR_*` only. The regression this criterion actually guards
is narrower and can be driven directly: if the fix calls `sys.exit()` *inside*
`capture_subprocess_output` instead of returning a status, the `rocminfo` call at
`omniprobe/omniprobe:225` kills the interpreter during ISA detection. AC-6 exercises exactly that
call shape with a failing command.

**AC-4 must drive the class, not a module-level function.** The API surface is
`Omniprobe(...).analyze_memory(command)`, and `_run` splits `command` on whitespace — so a quoted
`sh -c '…'` cannot survive it and the crashing target has to be a single-token script.

### Reproduction status at filing

Running this gate at `8de44b0`, before any fix, reproduced the defect and its downstream
consequence directly:

    FAIL  AC-1  target exited 42 but omniprobe reported 0
    FAIL  AC-2  target died of SIGSEGV and omniprobe reported 0
    PASS  AC-3  successful target still yields exit 0
    FAIL  AC-4  API returned an empty result on a crashing target
    FAIL  AC-5  no JSON output file produced on a failing run
    PASS  AC-6  capture_subprocess_output returns instead of exiting

AC-3 and AC-6 passing at filing is correct and load-bearing: they are the two regression guards,
and a gate whose guards fail before the work starts cannot distinguish a fix from a break.

## References

- `.agents/workflows/seeds/bf_exit-status-not-propagated.md` — the originating seed, committed
  unedited.
- `omniprobe/omniprobe:119` `capture_subprocess_output`; `:169` the comment that does not read the
  status; `:225` the `rocminfo` caller; `:823` the discarded call; `:825` `finalize_json_output`.
- `omniprobe/api/omniprobe.py:154` the returncode check; `:164` the `"[]"` fallback.
- `.agents/pm/units/omniprobe-cli.md` — PM unit covering this script.

## Open Questions

1. Does the **Triton** path drive `omniprobe` in a way that would newly fail once the status
   propagates — e.g. a target that has always exited nonzero harmlessly? Unmeasured. Check before
   step 3; the failure policy says report rather than special-casing it back to silence.

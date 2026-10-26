# Artifacts — bf_exit-status-not-propagated

## Inputs

| Item | Where | What it is |
|---|---|---|
| Originating seed | `.agents/workflows/seeds/bf_exit-status-not-propagated.md` | The incoming report, committed unedited. Superseded by `dossier.md`, which adds verification. |
| Filing agent's measurement | in the seed, § Measured | gfx950 / ROCm 7.2.0 at `44547f9`: exit 0 reported for a SIGSEGV death; 139 when the target is run directly with omniprobe's own environment. |

## Verified in this repository at `8de44b0`

    omniprobe/omniprobe:169    # Get process return code   <- followed by a read of stdout, not status
    omniprobe/omniprobe:823    capture_subprocess_output(...)  <- result discarded
    omniprobe/omniprobe:825    finalize_json_output(...)       <- runs after; constrains exit ordering
    omniprobe/omniprobe:225    capture_subprocess_output(["rocminfo"], ...)  <- second caller
    omniprobe/api/omniprobe.py:154   if result.returncode != 0:  <- the sole failure check
    omniprobe/api/omniprobe.py:164   return "[]"                 <- the quiet degradation

## Produced

All three items formerly listed here as outstanding were produced:

- The reproduction transcript at the base commit — `run-log.md`, Plan Of Record step 1.
- The three decisions (signal convention, exit-versus-finalize ordering, failed-measurement
  distinction) — `run-log.md` § the three decisions, summarised in `handoff.md`.
- `tests/test_exit_status.sh`, registered as suite 11 in `tests/run_all_tests.sh`, green —
  transcript below.

## Closing gate output — 2026-10-26, `k006-004-v3.hpcfund` (gfx90a / MI210), ROCm 7.2.0

    PASS  AC-1     target exiting 42 is reported as 42
    PASS  AC-2     target killed by SIGSEGV is reported as 139
    PASS  AC-3     successful target still yields exit 0
    PASS  AC-4     API raises RuntimeError on a crashing target
    PASS  AC-5     JSON output on a failing run is present and parses
    PASS  AC-6     capture_subprocess_output returns on a failing command instead of exiting — the rocminfo caller is safe
    PASS  AC-7     the new suite is registered and actually ran inside run_all_tests.sh
    PASS  AC-8     run_all_tests.sh: exit 0, 0 failed, 0 skipped
    PASS  SCOPE    no writes outside the declared write scope (4 entries; working tree and commits since 24fcd82085fa6b3d1e3788255548ac3752882bac)

    9 passed, 0 weak, 0 judgement, 0 failed
    ACCEPTANCE PASSED

**No `JUDGE` lines and no `WEAK` lines.** Every criterion was established by a direct check, so
no human acknowledgement is outstanding under workflow-complete step 2.

Supporting transcript: `tests/run_all_tests.sh` → `Suites run 11, passed 11, skipped 0,
failed 0`, exit 0. Full log at `.untracked/ac8-run-2026-10-26.log` (untracked — node-local).

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

## Still to be produced

- A reproduction transcript at the base commit (Plan Of Record step 1).
- The three recorded decisions: signal convention, exit-versus-finalize ordering, and whether a
  nonzero workload status is distinguished from a failed measurement.
- `tests/test_exit_status.sh` and a `run_all_tests.sh` transcript showing it registered and green.

# Handoff

## Current Status

Done 2026-11-08. All ACs met (artifacts.md). Suite 12 "Output file integrity" now guards it.

## What Was Decided

- Separator by file emptiness, not by dispatch id or static state (dossier Plan step 2).
- Truncation in the CLI, not in C++: the CLI runs the target once per invocation and is the only
  place that knows a run is starting; a per-process C++ truncation would clobber output of a
  target that forks instrumented children.
- `-l` CSV files are overwritten too (previously appended). Documented in `--help`.

## Active Risks / Blockers

- Direct `LD_PRELOAD` users (no CLI) still get no truncation and no closing `]`. No test or doc
  covers that path today.

## Next Exact Step

None for this packet. Follow-ups: `bf_bba-hardening` (BBA segfault on non-BBStart binaries).

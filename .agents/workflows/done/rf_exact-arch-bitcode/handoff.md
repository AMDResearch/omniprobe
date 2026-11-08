# Handoff: rf_exact-arch-bitcode

## Current Status
Done 2026-11-08. All acceptance criteria met; AC-7 runtime results recorded in run-log (MI350).

## Follow-ups (not in this packet)
- 1- and 2-byte LDS accesses on gfx950 are not measured (lds_conflict_sets has 4/8/16 only).
- Final main not re-run on gfx90a (see run-log); next gfx90a session: run the full suite once.
- lds_conflict_sets/analyze.py compares only with the CDNA1-3 model ("differs" on gfx950 is expected).

# Run-Log

## Log Entries

### 2026-11-08 — created; diagnosed; phase 1 (crash hardening) done

- Reproduced: Pennant `-k gpuMain3_interior` rc 139; ikimpl's branch kernel p50 4–24 M cycles,
  block 0 at line 0; AddressMessages binary rc 139 (survey).
- Subagent code study (findings with file:line in dossier § Diagnosis). Measured: 16-wave grid →
  p50 25–60 k (contention scaling); block IDs reorder between identical runs.
- Fix: `handle()` ignores non-BBStart messages and out-of-range indices with a one-time warning.
  BBInterval messages are now ignored too (they hit `assert(false)` before, compiled out → bogus
  values).
- New `tests/test_bba_robustness.sh` (suite 14): unfixed rc 139 on test 1; fixed 2/2. Pennant
  (AC-3) rc 0 with the out-of-range warning. Full suite 14/14.

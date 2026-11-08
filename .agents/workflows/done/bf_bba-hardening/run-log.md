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

### 2026-11-08 — phase 2 (ruling: option 1) done

- Plugin: block attributed to first located instruction, through inlining to the kernel's own
  line (ikimpl's kernel: lines 8,13,21,17,25,26 instead of header lines / 0).
- Handler rewritten: `blocks_` keyed by user_data; file from hash ↔ kernelDB file names; JSON/CSV
  report id, file, line, column, wave_visits, active_lanes. Timing removed (no opt-in kept).
- Logger CSV: no JSON rows; lazy per-kind headers; WAVE_MESSAGE rows for BBStart messages.
  Found that the block-filter, scope-filter and Triton scope tests counted the stray JSON lines in
  CSV output; switched them to `-t json -o` files (the full suite stopped at test 7 until then).
- MemoryAnalysis/Heatmap warn once on non-address messages.
- Unfixed (phase-1) code vs new checks: suite 15 3/3 FAIL, suite 12 CSV checks 2/2 FAIL.
  Fixed: all pass; full suite 15/15; API unit tests 10/10.
- Pennant (`-k gpuMain3_interior`, binary built earlier with the old plugin): rc 0, 8 blocks with
  counts; lines are the old plugin's (header lines) until Pennant is rebuilt with this plugin.

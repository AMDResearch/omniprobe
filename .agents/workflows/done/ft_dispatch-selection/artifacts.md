# Artifacts: ft_dispatch-selection

- design.md — survey, options, ruling inputs.
- Code: `cd5e5c4` (parsers + case table), `ea98dd6` (test + app), `949b03d` (runtime, launcher,
  handlers, API), `be71a55` (suite 27 replaced), `014d779` (docs).

## Fails-before (base runtime `e866d24`, new tests from `ea98dd6`, gfx950, 2026-11-09)

`tests/test_dispatch_selection.sh` against the base build: AC-1/AC-2 pass (parsers added
first, not used by the runtime yet); every AC-3..AC-7 check fails:
- AC-3: `-d 5x`, `-d 0`, `-d '1, 2'`, `-d random` all accepted, application started (rc 0).
- AC-4 (uninitialised-flag defect): `LOGDUR_DISPATCHES=5x` → no message, **all 4 dispatches
  instrumented** (`dispatch_select_test 2`).
- AC-5: `-d 2,5`, `-d 1,3,4:3`, `-d 10-` etc. each instrumented all 24 dispatches (the same
  defect: unrecognised values fell through to indeterminate flags, which here read as "all").
- AC-6/AC-7: no `kernel_dispatch` anywhere; CSV header without the column.

## After (gfx950, 2026-11-09)

- `acceptance.sh` under `flock /tmp/gpu-measure.lock`: 9 PASS, AC-9 WEAK, SCOPE PASS.
- Full suite: 27 run, 24 passed, 3 skipped (suites 3–5, rocBLAS/hipBLASLt: instrumented libs are
  gfx90a-only, N/A on gfx950), 0 failed. Suite 2 first failed: a stale gfx90a
  `tests/library_filter_chain/build` segfaulted without omniprobe; deleted, rebuilt, passed.
- `run_module_load_tests.sh`: 3/3.
- gfx90a re-check pending (MI210 node).

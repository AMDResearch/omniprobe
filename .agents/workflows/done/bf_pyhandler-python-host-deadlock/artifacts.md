# Artifacts: bf_pyhandler-python-host-deadlock

- Commits: `11f2293` (test, fails before), `ff9eedb` (fix, suite 28, docs).
- Investigation logs (untracked): `.untracked/pyhost/` — gdb stacks `stk2.txt` (PyDLL), `tstk.txt`
  (Triton), fails-before `fails-before.log`, after `after3.log`, acceptance `acceptance.log`.

## Fails-before (build `bdd1bd3` + test `11f2293`, gfx950, 2026-11-09)

AC-1 Triton: timeout 180 s, 0 reports. AC-2 PyDLL: timeout 120 s, 0 reports. AC-5: silent hang
(no warning). AC-3 (CDLL 3.12, 3.9) and AC-4 (busy thread) passed — regression guards.

## Intermediate (recorded because it found a second defect)

Check-in moved out of the locks but still on signal_runner: AC-1 passed, AC-2 still hung (the
signal runner, blocked in a check-in waiting for the GIL, could not complete the memcpy blit the
host waited for). Moving check-in to comms_runner fixed AC-2 but made the host's exit race the
last check-in: AC-2..AC-4 segfaulted (rc 139) with the last report missing. The atexit hook
(wait until idle, GIL released) and the finalization guards fixed that.

## After (gfx950, 2026-11-09)

- `tests/test_python_host.sh`: 6/6, three consecutive runs.
- Suite 19 (PythonHandler): 10/10.
- `acceptance.sh` under `flock /tmp/gpu-measure.lock`: AC-1..AC-6 PASS, AC-7 WEAK; SCOPE PASS after
  the `inc/interceptor.h` amendment. Full suite: 28 run, 25 passed, 3 skipped (3–5, N/A on
  gfx950), 0 failed.

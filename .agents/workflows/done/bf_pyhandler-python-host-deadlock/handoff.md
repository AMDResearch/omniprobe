# Handoff: bf_pyhandler-python-host-deadlock

State: done 2026-11-09 on gfx950. Open: gfx90a re-run (MI210). Follow-ups not done (non-goals):
batch GIL acquisition per sub-buffer (busy Python thread slows handlers: measured 0.9 s → 11 s on
3.12, 120 s on 3.9 with 1024×2000 loads); build/locate the plugin per host Python version.

## Scope Amendments

- 2026-11-09: `inc/interceptor.h` — the check-in queue (members, queueCheckin/nextCheckin/idle).

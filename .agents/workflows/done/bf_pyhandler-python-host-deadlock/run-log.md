# Run log: bf_pyhandler-python-host-deadlock

- 2026-11-09 — Investigation (Rene's deferred item) found the deadlock; measurements in dossier
  § Background. Packet opened active at `bdd1bd3`.
- 2026-11-09 — Test `11f2293` fails before (AC-1, AC-2, AC-5). Fix in three steps (artifacts.md
  § Intermediate); `ff9eedb`. Scope amended: `inc/interceptor.h`. Acceptance passed on gfx950.

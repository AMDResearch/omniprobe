# Run log: ft_dispatch-selection

- 2026-11-09 — Design note (design.md) written and committed (`e866d24`); four syntax options.
- 2026-11-09 — Supervisor ruled: Option A plus the rules recorded in dossier § Ruling. Contract and
  AC-1..AC-9 written; packet promoted to active, base commit `e866d24`. `build/` reconfigured for
  gfx950 (this node); reconfigure back to gfx90a on an MI210 node.
- 2026-11-09 — Parsers (Python/C++) + 74-case shared table; test app + test script; fails-before
  recorded on the base runtime (artifacts.md). Runtime/launcher/handlers/API implemented; all
  AC checks pass; suite 27 replaced; docs. Full suite on gfx950: 24 pass, 3 N/A, 0 fail;
  module-load 3/3. Acceptance PASSED (AC-9 WEAK).

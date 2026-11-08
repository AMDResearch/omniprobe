# Handoff: rf_rename-logduration-to-omniprobe

## Current Status
**State**: Active — TODO. Dossier complete but not started. Open questions need user input.

## What Was Done
- Comprehensive codebase survey identifying all occurrences across 30+ files
- 10-step micro-plan with verification gates

## Next Step
Resolve open questions (library name, env var prefix, backward compat), then execute step 1.

## Blockers
Open questions need user input before starting.

## Proposed Spec Changes
None.


## Note added 2026-11-08 (supervisor request; not fixed)

`docs/usage.md` § Environment variables documents `OMNIPROBE_*` names (`OMNIPROBE_INSTRUMENTED`,
`OMNIPROBE_HANDLERS`, `OMNIPROBE_LOG_FORMAT`, ...), but the code reads `LOGDUR_*`
(`src/utils.cc` getLogDurConfig; the CLI sets `LOGDUR_*`). The table's note says they "will be
renamed"; until this packet runs, the table describes variables that do nothing. Fix the docs and
the code together here.

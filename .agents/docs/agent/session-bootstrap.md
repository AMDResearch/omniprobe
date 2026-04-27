# Agent Session Bootstrap

This document defines how an agent initializes a session. The canonical procedure is the `session-init` skill (`.agents/skills/session-init/SKILL.md`).

## Required Read Order

Read these files in this order. Do not skip any file marked required.

1. `.agents/project.json` (required) — project name, type, facets, adapter config.
2. `.agents/adapters/shared-entrypoint.md` (required) — cross-adapter policies and working rules.
3. `.agents/state/current-focus.md` (required) — what the last session left for this one.
4. `.agents/state/active-workflows.md` (required) — all in-flight workflows, owners, write scopes.
5. `.agents/bootstrap/reading-paths.md` — guidance for different session types.
6. `.agents/pm/pm-index.md` — scan unit names and "when to load" column; do not read full units yet.

## Session Type Classification

After reading the required files, classify the session:

- **Directed work**: The user gave a specific task. Match it to an existing workflow or identify that a new one is needed.
- **Workflow resume**: `current-focus.md` or the user points to a specific workflow. Prepare to resume it.
- **Open session**: No specific direction. Present a briefing and wait for user instruction.

## Additional Reads By Session Type

| Session type | Additional reads |
|---|---|
| Directed work (existing workflow) | Packet `handoff.md`, then `dossier.md`. PM units listed in dossier metadata. |
| Directed work (new work) | `.agents/pm/pm-current-state.md` for context. |
| Workflow resume | Packet `handoff.md`, then `dossier.md`. PM units listed in dossier metadata. |
| Open session | None until user provides direction. |

## Decision Rules

- **User instruction vs `current-focus.md` conflict**: Prefer the user's explicit instruction. Note the divergence in your briefing.
- **Missing files**: If `project.json` is missing, stop and tell the user to run `amplify`. If `current-focus.md` is empty or placeholder, treat as an open session.
- **Dangling workflow references**: If `active-workflows.md` references workflow directories that do not exist, report the dangling references and continue.
- **Multiple unowned workflows**: List them in your briefing. Do not pick one without user direction.

## Stop Conditions

- `project.json` missing → stop, report, suggest `amplify`.
- `shared-entrypoint.md` missing → stop, report. The repo may not be properly amplified.
- User explicitly says to skip bootstrap → comply, but note that session state may be stale.

## What Not To Load

- Do not read full PM units during bootstrap. Scan the index only.
- Do not read `run-log.md` files unless explicitly resuming a workflow and needing execution history.
- Do not read tutorial or example docs. Those are for humans.

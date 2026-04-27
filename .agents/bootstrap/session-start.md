# Session Start

Run the `session-init` skill to bootstrap this session.

The canonical bootstrap procedure lives in `.agents/skills/session-init/SKILL.md`. It reads project metadata, identifies the current focus and active workflows, classifies the session type, and tells you what else to load.

## Quick Summary

`session-init` will:

1. Read `.agents/project.json` and `.agents/adapters/shared-entrypoint.md`.
2. Read `.agents/state/current-focus.md` and `.agents/state/active-workflows.md`.
3. Classify the session as directed work, workflow resume, or open.
4. Queue additional reads (handoff, dossier, PM units) based on the session type.
5. Deliver a concise briefing.

If the `session-init` skill is not available, follow the reading paths in `.agents/bootstrap/reading-paths.md` manually.

## After Bootstrap

- If resuming a workflow, the agent reads the packet's `handoff.md` and `dossier.md` next.
- If starting new work, create or refine a workflow packet before proceeding autonomously.
- If no direction exists, present the briefing and wait for user instruction.

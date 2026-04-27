# Shared Entrypoint

This repository is using the Agentic Meta Project structure for a `code` project with facets `code, design`.

## Canonical Locations

- Policy: `.agents/policy/` — read `.agents/policy/guardrails.md` at session start.
- Bootstrap docs: `.agents/bootstrap/`
- Project Memory: `.agents/pm/`
- Workflows: `.agents/workflows/`
- Project handoff: `.agents/state/current-focus.md`
- Parallel coordination: `.agents/state/active-workflows.md`

## Session Start

Run the `session-init` skill (`.agents/skills/session-init/SKILL.md`) to bootstrap this session. It reads project metadata, identifies the current focus and active workflows, classifies the session type, and tells you what else to load.

If `session-init` is unavailable, follow the manual reading paths in `.agents/bootstrap/reading-paths.md`.

## Working Rules

- Do not weaken or rewrite acceptance criteria without user approval.
- If the contract cannot be met, stop and report the blocker.
- Update `handoff.md` after every significant step, not just at session end. Sessions can be aborted without warning.
- Append to `run-log.md` after every meaningful execution step.
- **Session start:** run `/session-init` (always).
- **Session end:** run `/session-close` (bundles PM updates, workflow doc updates, commits,
  and session capture). If `/session-close` is unavailable, manually: update PM and workflow
  docs, commit in logical groups, then run `/session-capture`.
- Before parallel work, confirm your workflow's intended write scope does not silently collide with another active workflow.
- Follow the checkpoint protocol in `guardrails.md` — checkpoint after completing an AC,
  after >3 file changes, after verification, and before long operations.

## Session Aborts

Sessions can end unexpectedly (context exhaustion, timeout, user disconnect). The system
tolerates this: `/session-init` detects signs of an incomplete prior session (session-active
marker, uncommitted changes, stale handoffs, missing captures) and recommends recovery steps.
The checkpoint protocol ensures that at most the work since the last checkpoint is lost. Use
`/session-close` when possible, but skipping it is not catastrophic.

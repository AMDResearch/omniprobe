# Workflow Index

## Seeds vs Packets

Rough work requests that are not yet structured enough to be a workflow packet live in `.agents/workflows/seeds/` as plain markdown files. They are not packets — they have no dossier, run-log, handoff, or artifacts file.

When a seed is refined into a structured packet (via `workflow-refine` or `workflow-create`), it becomes a packet directory under the appropriate lifecycle state directory.

## Workflow Type Prefixes

- `rf_` — refactor
- `ft_` — feature
- `bf_` — bug fix
- `iv_` — investigation
- `rv_` — review
- `pf_` — performance

## Packet Lifecycle States

Workflow packets live under `.agents/workflows/<state>/<workflow-id>/`.

- `draft` — structured packet exists but is not yet approved for autonomous execution
- `active` — approved and being executed
- `suspended` — paused intentionally; can be resumed
- `blocked` — cannot proceed; waiting on an external dependency or decision
- `failed` — contract could not be met; agent stopped
- `done` — completed and accepted
- `abandoned` — intentionally dropped; will not be resumed

## Packet Files

Each packet directory contains:

- `dossier.md` — the contract and plan
- `run-log.md` — append-only execution history
- `handoff.md` — concise resume state for cross-session handoff
- `artifacts.md` — output index and verification evidence

## Moving Packets Between States

The agent moves a packet by relocating its directory from one lifecycle directory to another (e.g., `draft/ft_login/` to `active/ft_login/`). After every move:

1. Update the packet's `dossier.md` metadata to reflect the new lifecycle state.
2. Update `.agents/state/active-workflows.md` to reflect the new state.
3. Update `.agents/workflows/INDEX.md` if a tracking table is maintained there.

The user must approve the transition from `draft` to `active`. All other transitions may be initiated by the agent when warranted by the execution state.

## Coordination

Use `.agents/state/active-workflows.md` to coordinate multiple workflows in parallel.

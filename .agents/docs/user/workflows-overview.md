# Workflows Overview

Workflow packets are the handoff protocol for substantial autonomous work.

## When To Use One

Use a workflow when the task needs a clear contract, can span multiple sessions, or benefits from explicit verification and handoff state.

## Seeds vs Packets

A **seed** is a rough work request stored as a plain markdown file in `.agents/workflows/seeds/`. It is not a structured packet — it is just a starting note that captures a rough idea before refinement.

When a seed is refined (via `workflow-refine` or `workflow-create`), it becomes a **packet** — a directory containing `dossier.md`, `run-log.md`, `handoff.md`, and `artifacts.md`.

## Packet Lifecycle States

Packets live in directories named by their current state:

- `draft` — structured but not yet approved for autonomous execution. You should review the dossier and approve the objective, scope, acceptance criteria, and failure policy before the agent begins.
- `active` — approved and being executed. The agent works against the contract.
- `suspended` — paused intentionally. The work can be resumed later.
- `blocked` — cannot proceed. Waiting on an external dependency or decision.
- `failed` — the contract could not be met. The agent stopped and reported why.
- `done` — completed and accepted.
- `abandoned` — intentionally dropped. Will not be resumed.

## Packet Files

- `dossier.md` — the contract and plan. Contains the objective, scope, acceptance criteria, failure policy, and plan of record.
- `run-log.md` — append-only execution history. Each entry records what was planned, what was done, what the result was, and which files were touched.
- `handoff.md` — concise resume state. A later session reads this first to know exactly where to pick up.
- `artifacts.md` — output index and verification evidence. Points to reports, benchmarks, patches, or other outputs.

## Coordination Files

- `.agents/state/current-focus.md` — project-wide summary and reading path for the next session
- `.agents/state/active-workflows.md` — the concurrent workflow index showing all non-done workflows

When multiple workflows run in parallel, you usually watch `active-workflows.md` plus the relevant `handoff.md` files, not the full run logs.

## How Packets Move Between States

The agent moves a packet by relocating its directory (e.g., from `draft/ft_login/` to `active/ft_login/`). The transition from `draft` to `active` requires your approval. Other transitions are initiated by the agent when the execution state warrants it.

After every move, the agent updates the dossier metadata and `active-workflows.md` to stay in sync.

## State Archival

When a workflow reaches a terminal state (`done`, `abandoned`, or `failed`), the `workflow-complete` skill archives it:

- The workflow's entry moves from the Active section to the Completed section in `active-workflows.md`, preserving a record of what was done and when.
- The workflow's entry in `current-focus.md` is pruned so that future sessions do not waste context loading finished work.

This keeps coordination files focused on live work while retaining a searchable history of completed workflows.

## Readiness Checks

Before a workflow transitions from `draft` to `active`, a readiness check verifies that the dossier has a clear objective, acceptance criteria, and a plan of record. For design-heavy workflows (architecture spikes, research investigations), readiness checks may flag ambiguity warnings — for example, acceptance criteria that are subjective or a plan of record with exploratory steps that lack clear exit conditions. These warnings do not block the transition; they alert you to areas where the contract may need tightening after early findings emerge.

## Autonomous Execution On Resume

When you ask the agent to resume or execute a workflow, it runs autonomously by default. The agent picks up from `handoff.md`, follows the plan of record, and works through remaining steps without pausing for per-step approval. It stops when it completes the plan, hits a guardrail, encounters a blocker, or cannot satisfy an acceptance criterion. If you want more control, request step-by-step execution at the start of the session.

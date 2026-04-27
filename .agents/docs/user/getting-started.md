# Getting Started

This repository has been amplified with the Agentic Meta Project — a portable system for structured agent work across sessions.

## First-Time Setup

After amplification, run these commands in your first agent session:

1. Run `/session-init` — bootstraps the agent with project metadata, policies, and current state.
2. Run `/pm-init` — builds project memory from the codebase (if not done during amplification).

After this, the agent is ready to work. You only need to run `/pm-init` once per project.

## Session Lifecycle

Every session follows a standard open/close pair:

- **`/session-init`** opens the session. Run it at the start of every session to load project state, policies, and current focus.
- **`/session-close`** closes the session. Run it at the end of every session. It bundles PM updates, workflow doc updates, commits, and session capture into a single command so nothing is forgotten.

This pair replaces any manual end-of-session checklist. If you previously performed separate steps to update handoff docs, commit changes, and capture session notes, `/session-close` handles all of that.

## Autonomous Execution

When you ask the agent to execute a workflow, it runs autonomously by default. The agent follows the plan of record in the dossier without pausing for approval at each step. It will stop on its own if it hits a guardrail, a blocker, or an unmet acceptance criterion. You can override this by requesting step-by-step execution or explicit approval gates.

## Your First Action

To start your first task, tell your agent:

> Use workflow-refine to turn this into a workflow: [describe your task in plain language]

The agent will ask clarifying questions, propose a structured workflow, and present it for your review. You approve the objective, scope, and acceptance criteria before autonomous work begins.

If your task is small enough that a full workflow feels heavy, just ask the agent directly — not everything needs a packet.

## What `.agents/` Contains

| Directory | Purpose | Who reads it |
|---|---|---|
| `project.json` | Machine-readable project metadata | Agent |
| `adapters/` | Shared and runtime-specific entrypoint docs | Agent |
| `policy/` | Contract preservation, guardrails, verification rules | Agent (you can review) |
| `pm/` | Project Memory — durable shared project knowledge | Agent (you can review) |
| `workflows/` | Workflow packets for substantial work | Both |
| `state/` | Project-wide handoff and workflow coordination | Both |
| `skills/` | Skill docs that tell agents how to perform tasks | Agent |
| `docs/user/` | Documentation for humans (you are here) | You |
| `docs/agent/` | Operating protocols for agents | Agent |
| `docs/examples/` | Example workflow packets | Both |

## The Short Version

Most humans only need five things:

1. Start from a rough task request.
2. Let the agent refine it into a workflow packet when the task is substantial.
3. Review the dossier: objective, scope, acceptance criteria, and failure policy.
4. Let a later session execute from the packet handoff.
5. Review outcomes and ask for revisions when needed.

You usually do not need to read `run-log.md`, most PM units, or agent docs unless you want to inspect how the agent coordinates itself.

## What Project Memory Means

Project Memory (PM) is the durable shared knowledge layer. It stores stable truths, durable decisions, and negative knowledge (things that were tried and should not be repeated). It is not a transcript archive — it captures only what future sessions need to reuse.

## Root Wrapper Files

- `AGENTS.md` — a thin wrapper that points agents to the shared entrypoint. It is primarily for agent runtimes, not for human reading.
- `CLAUDE.md` — same, with Claude-specific additions.

## Reporting Issues

If you encounter friction, bugs, or have suggestions for the Agentic Meta Project, tell your agent to run `/feedback`. It will collect your report and file it as a GitHub issue (or save it locally if `gh` is not available).

## Read Next

1. [How to Work with an Agent](how-to-work-with-an-agent.md) — the human operating model
2. [Workflows Overview](workflows-overview.md) — what workflows are and when to use them
3. [Tutorials](tutorials/) — complete session walkthroughs for every workflow type
4. `.agents/bootstrap/amplify-installation-report.md` — what was installed and what to review
5. [Project Memory Overview](project-memory-overview.md) — what PM is for
6. [Parallel Work](parallel-work.md) — running multiple workflows concurrently

# How To Work With An Agent

This document explains the human-facing operating model.

## High-Level Session Outline

1. You start with a rough request.
2. The agent uses `workflow-refine` or `workflow-create` to turn that rough request into a stronger workflow packet or seed.
3. You review only the contract-critical parts: objective, scope, acceptance criteria, and failure policy.
4. A later session resumes from `handoff.md` and executes the work.
5. You review the result and decide whether to continue, revise, or close the workflow.

## What Humans Usually Need To Read

- `.agents/docs/user/getting-started.md` — start here
- `.agents/docs/user/tutorials/` — complete session walkthroughs
- workflow `dossier.md` — the contract for each work item
- workflow `handoff.md` — the short resume state
- `.agents/state/active-workflows.md` — when multiple workflows exist

## What Humans Can Usually Ignore

- most of `run-log.md` unless you want the history
- most PM units unless the task touches architecture or durable decisions
- most agent docs under `.agents/docs/agent/`

## Why The System Uses So Many Files

- `dossier.md` is the contract
- `handoff.md` is the short resume note
- `run-log.md` is the detailed execution history
- `artifacts.md` points to evidence and outputs
- PM stores reusable project knowledge that outlives one workflow

## Typical Two-Session Pattern

Session 1:

- give the agent a rough brief
- ask it to refine the brief into a workflow packet
- review the packet contract

Session 2:

- ask the agent to resume the workflow from `handoff.md`
- let it implement or investigate against the approved packet
- review the results

See `.agents/docs/user/tutorials/` for complete examples of every workflow type.

## Autonomous Execution

When you ask the agent to execute a workflow, it operates autonomously by default. This means:

- **What it does:** The agent executes the workflow's plan of record from start to finish without pausing for your approval at each step. It reads the dossier, follows the plan, and produces the deliverables.
- **When it stops:** The agent stops autonomously when it encounters a guardrail stop condition, a blocker it cannot resolve, or acceptance criteria it cannot satisfy. It records why it stopped and what remains.
- **How to override:** If you want more control, request step-by-step execution ("execute one step at a time and show me the result") or explicit approval gates ("pause after each phase for my review"). The agent will comply for the remainder of that session.

Autonomous execution is the recommended default for most workflows. It lets the agent make the most of a single session. Reserve step-by-step mode for high-risk changes or when you want to learn how the agent works.

## Ending A Session

Use `/session-close` as the standard way to end a session. It bundles several end-of-session tasks into one command:

- Updates workflow documents (handoff, run-log) to reflect current state.
- Performs any pending PM updates for durable knowledge learned during the session.
- Commits outstanding changes.
- Captures a portable session record for future review.

You do not need to perform these steps manually.

## What Happens If A Session Is Interrupted

Session aborts are tolerated. If a session ends without `/session-close` (context exhaustion,
timeout, disconnect), the system detects and recovers:

- The agent follows a checkpoint protocol during active work, saving progress to `handoff.md`
  and `run-log.md` at regular intervals. At most the work since the last checkpoint is lost.
- The next `/session-init` detects the incomplete session (uncommitted changes, stale handoffs,
  missing captures) and recommends recovery steps.
- Recovery is guided, not automatic: the agent shows you what it found and suggests a sequence
  to bring state files up to date before starting new work.

Use `/session-close` when you can, but missing it is not catastrophic.

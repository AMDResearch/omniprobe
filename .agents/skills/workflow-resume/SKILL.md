---
name: workflow-resume
description: |
  Resume work on an existing workflow in a new session. Use when the user says
  "resume", "continue", "pick up where we left off", or names a specific
  workflow ID to work on. Loads the handoff, dossier, and run-log, then begins
  executing the next step.
---

# workflow-resume

## Purpose

Load the minimum context needed to continue working on an existing workflow in a new session. This is the most common agent entry point for returning sessions. The goal is to get oriented quickly without reading everything -- load what you need, skip what you do not.

## Preconditions

- A workflow packet exists in `.agents/workflows/<state>/<workflow-id>/` where state is `active`, `suspended`, or `blocked`.
- The workflow ID is known (provided by the user, found in `active-workflows.md`, or identified via `current-focus.md`).

## Required Reads

Read in this exact order. Stop loading as soon as you have enough context to take the next step.

1. `.agents/workflows/<state>/<workflow-id>/handoff.md` -- read this first. It tells you the current status, the exact next step, active risks, and what else you need to read.
2. `.agents/workflows/<state>/<workflow-id>/dossier.md` -- read the Objective, Acceptance Criteria, Scope, and Plan of Record. Skip Background/Context and References unless the handoff says you need them.
3. `.agents/state/active-workflows.md` -- check for parallel workflows and write-scope conflicts before making changes.
4. PM units listed in the handoff's "Required Reads Before Resuming" section, if any.
5. `.agents/workflows/<state>/<workflow-id>/run-log.md` -- read only the last 3-5 entries unless the handoff indicates you need more history.

## Procedure

1. **Identify the workflow.** If the user names it, use that. Otherwise, read `.agents/state/active-workflows.md` or `.agents/state/current-focus.md` to find the most likely candidate.
2. **Read the handoff file first.** Extract: current status, next exact step, active risks/blockers, and required reads.
3. **Read the dossier selectively.** Load the contract-controlled sections (Objective, Acceptance Criteria, Failure Policy, Scope, Non-Goals). Load other sections only if the handoff references them.
4. **Check for blockers.** If the handoff lists active blockers, assess whether they are resolved. If still blocked, report to the user and stop.
5. **Check for parallel work conflicts.** Read `active-workflows.md`. If another workflow's write scope overlaps with yours, note this before proceeding.
6. **Declare execution mode.** Unless the user explicitly requests otherwise, default to
   autonomous execution. State to the user:

   "I will execute <workflow-id> autonomously against its acceptance criteria. I will only
   stop if: a stop condition from the guardrails is triggered, a blocker is encountered that
   requires your input, or an acceptance criterion cannot be met."

   Then proceed without waiting for confirmation. If the user has given a directive like
   "execute <workflow-id>" or "work on <workflow-id>", treat it as authorization for
   autonomous execution.
7. **Begin the next step** as described in the handoff. Log the session start in `run-log.md`
   with a new entry that includes the execution mode and checkpoint expectation:
   `Execution mode: autonomous. Checkpointing per guardrails § Checkpoint Protocol.`
   Follow the checkpoint protocol throughout the session — update `handoff.md` and append
   to `run-log.md` at each trigger defined in `guardrails.md`.

## Output

- **Location**: No new files are created. Updates go to:
  - `.agents/workflows/<state>/<workflow-id>/run-log.md` -- append a session-start entry.
  - `.agents/workflows/<state>/<workflow-id>/handoff.md` -- update before session ends.
- **Format**: Run-log entries follow the run-log template fields (timestamp, actor, planned step, action taken, result, files touched, verification run, criteria impact, blocker or risk).

## Completion Criteria

- The agent has read the handoff and dossier and can state the next concrete action without guessing.
- A session-start entry has been appended to the run-log.
- The agent is ready to execute the next step from the handoff. The resume itself is complete when execution begins.

## Error Handling

- If the workflow ID does not match any packet directory, list available workflows from `active-workflows.md` and ask the user to clarify.
- If the handoff file is empty or missing "Next Exact Step," read the full run-log to reconstruct the last known state. Then update the handoff before proceeding.
- If the workflow state is `blocked` or `failed`, do not silently resume. Report the state to the user and ask how to proceed.
- If the dossier's contract-controlled sections have been modified since the last session (compare with run-log), flag this to the user -- it may indicate an unauthorized spec change.

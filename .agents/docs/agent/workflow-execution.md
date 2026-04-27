# Workflow Execution

This document defines how an agent executes against a workflow packet without silently changing the contract.

## Contract-Controlled Sections

After a workflow reaches `active` state, do not substantively change these dossier sections:

- Objective
- Acceptance Criteria
- Failure Policy
- Scope
- Non-Goals

If any of these need modification, write the proposed change in `handoff.md` under `Proposed Spec Changes` and stop. Wait for user approval before continuing with a modified contract.

## Incremental State Persistence

After every significant milestone (build success, test pass, major code change), update `handoff.md` and append to `run-log.md` immediately. Do not batch these to end-of-session. If the session is interrupted, these files are the only recovery mechanism.

Context exhaustion is a form of session interruption. Treat it like an unexpected abort — state files should already be current if you have been updating them incrementally.

> **Mandatory**: After every meaningful step, append to `run-log.md`. This is not optional. If the session is interrupted, the run-log is the only record of progress.

## Checkpoint Procedure

A checkpoint is a quick state save: update `handoff.md` with current status and append a
run-log entry. It should take under one minute. See `guardrails.md` § Checkpoint Protocol
for the specific triggers (after completing an AC, after >3 file changes, after verification,
before long operations, when context usage is high).

**What to write in a checkpoint:**

1. **handoff.md** — rewrite `Current Status`, `Last Verified`, and `Next Exact Step` to
   reflect the state right now. Keep it concise.
2. **run-log.md** — append a standard entry. The `Planned step` field can say "checkpoint"
   if the checkpoint doesn't correspond to a specific plan step.

**Why checkpoints matter:** If the session ends unexpectedly, the next `session-init` will
detect the interruption (via the session-active marker and file timestamps) and guide recovery
from the last checkpoint. Without checkpoints, the entire session's context may be lost.

## Execution Loop

For each step in the Plan of Record:

1. **Read the plan step** from `dossier.md`.
2. **Check preconditions** — are dependencies met? Is the intended write scope still safe?
3. **Execute the step** — make the code/doc changes.
4. **Verify** — run relevant tests, checks, or manual inspection.
5. **Log the step** — append an entry to `run-log.md` with: timestamp, actor, planned step, action taken, result, files touched, verification run, criteria impact, blocker or risk.
6. **Update handoff** — rewrite `handoff.md` to reflect the new state.

## Acceptance Verification

After each meaningful phase or verification gate:

1. Assess whether all acceptance criteria remain satisfiable.
2. Record the assessment outcome: `continue`, `risk`, or `stop`.
3. If `stop`: check the failure policy in the dossier.
   - If `stop` → move the packet to `failed/`, update `active-workflows.md`, and report to the user.
   - If `best_effort` → log the unmet criterion, mark it as best-effort in `handoff.md`, and continue with the remaining criteria.

## Lifecycle State Transitions

The agent moves a packet by relocating its directory between lifecycle directories.

| Transition | Who initiates | When |
|---|---|---|
| `draft` → `active` | User (approval required) | After readiness check passes and user approves |
| `active` → `suspended` | Agent or user | When pausing intentionally |
| `active` → `blocked` | Agent | When an external dependency or decision prevents progress |
| `active` → `failed` | Agent | When acceptance criteria cannot be met and failure policy is `stop` |
| `active` → `done` | Agent | When all acceptance criteria are verified as met. Use the `workflow-complete` skill. |
| Any → `abandoned` | User | When intentionally dropping the work |

After every transition:

1. Update the `Lifecycle State` field in `dossier.md` metadata.
2. Update the matching row in `.agents/state/active-workflows.md`.
3. Update `.agents/state/current-focus.md` if the project focus changed.

## Parallel Execution

Before executing in parallel with other agents:

1. Read `.agents/state/active-workflows.md`.
2. Confirm your workflow's intended write scope.
3. If there is uncoordinated overlap in a high-risk area, stop and ask the user.
4. If another workflow lists the same write scope, check whether the overlap is explicitly coordinated in both dossiers. If not, stop.

## Decision Rules

- **Scope creep**: If you discover additional work that should be done but is outside the stated scope, note it in `handoff.md` under `Proposed Spec Changes`. Do not expand scope silently.
- **Conflicting state**: If `handoff.md` and `run-log.md` disagree about the current position, trust `handoff.md` (it should be rewritten after each step). If `active-workflows.md` and the packet's dossier metadata disagree about lifecycle state, trust the dossier and update `active-workflows.md`.
- **Missing verification**: If a step cannot be verified (e.g., no test exists), log the step as "unverified" in `run-log.md` and note it as a risk in `handoff.md`.

## Stop Conditions

- Acceptance criteria cannot be met and failure policy is `stop`.
- The intended write scope now overlaps with another active workflow without coordination.
- A dependency listed in the dossier is not met and cannot be resolved.
- The user explicitly asks you to stop.
- You discover you are modifying contract-controlled sections without approval.

## Session End Protocol

Before ending a session:

1. Update `handoff.md` to reflect the current state.
2. Append a final entry to `run-log.md` summarizing the session's work.
3. Run `session-capture` to persist a normalized session record.

If the session is ending unexpectedly (context exhaustion, timeout), prioritize updating `handoff.md` — it is the primary recovery mechanism for the next session.

## Run-Log Entry Format

Each append to `run-log.md` should follow this structure:

```markdown
### <timestamp>

- **Actor**: <agent identifier>
- **Planned step**: <what the plan of record says>
- **Action taken**: <what was actually done>
- **Result**: <success | partial | failure>
- **Files touched**: <list>
- **Verification**: <what was run and the outcome>
- **Criteria impact**: <which acceptance criteria are affected>
- **Blocker / Risk**: <any, or "none">
```

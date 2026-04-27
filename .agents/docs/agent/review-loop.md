# Review Loop

This document defines how an agent captures, reviews, and proposes process improvements at the end of a substantial session.

## When To Run The Review Loop

Run this at the end of any session that involved:

- Executing workflow steps.
- Making meaningful code or document changes.
- Encountering blockers, failures, or user course corrections.

Skip the review loop for trivial sessions (reading only, answering a quick question, no state changes).

## Step 1: Session Capture

If a session capture does not already exist, create one using the `session-capture` skill.

**Location**: `.untracked/session-captures/<YYYY-MM-DD>-<agent>.md`

**Required sections**:

```markdown
# Session Capture

## Metadata
- Date: YYYY-MM-DD
- Agent: <identifier>
- Session type: <directed | resume | open>
- Workflow(s): <IDs, or "none">

## Goal
<What the session set out to accomplish>

## Work Performed
<Summary of what was done, files changed, tests run>

## Verification
<What was verified and the outcomes>

## Decisions Made
<Decisions taken during the session and their rationale>

## Blockers and Unresolved Issues
<Anything that blocked progress or remains unresolved>

## PM Updates Needed
<What PM changes should be persisted, if not already done>
```

## Step 2: Identify Failure Modes

Review the session capture for the following failure-mode categories:

| Category | What to look for |
|---|---|
| Contract violation | Agent changed acceptance criteria or scope without approval |
| Scope drift | Agent did work outside the stated scope or non-goals |
| Over-reading | Agent loaded too much context, slowing the session |
| Under-documentation | Agent skipped run-log entries, handoff updates, or PM maintenance |
| Silent failure | Agent continued past a failed verification without reporting it |
| User correction | User had to redirect the agent mid-session |

## Step 3: Update Coordination State

1. Refresh `.agents/state/active-workflows.md` if workflow state, ownership, or write scope changed.
2. Refresh `.agents/state/current-focus.md` to reflect the current project state and recommended next actions.
3. Update `handoff.md` for any active workflow that was touched.

## Step 4: Write Review Artifacts

### Session Review

**Location**: `.agents/improvement/session-reviews/<YYYY-MM-DD>-<workflow-or-topic>.md`

**Format**:

```markdown
# Session Review: <date> — <topic>

## Summary
<1-2 sentence summary of what happened>

## What Worked
<Approaches or patterns that were effective>

## Failure Modes Observed
<List each failure mode with: category, description, impact, root cause>

## Recommendations
<Specific, actionable suggestions for future sessions>
```

### Local Proposal (when warranted)

Create a local proposal when a recommendation would change a template, policy, or process doc in this repo.

**Location**: `.agents/improvement/local-proposals/<YYYY-MM-DD>-<slug>.md`

**Format**:

```markdown
# Local Proposal: <title>

## Observation
<What was observed>

## Root Cause
<Why it happened>

## Proposed Change
<What to change, where, and why>

## Affected Files
<List of files that would change>

## Risk
<What could go wrong with this change>
```

### Forward-to-Meta Lesson (when warranted)

Create a forward lesson when the finding generalizes beyond this specific repo.

**Location**: `.agents/improvement/forward-to-meta/<YYYY-MM-DD>-<slug>.md`

**Format**:

```markdown
# Forward Lesson: <title>

## Observation
<What was observed>

## Root Cause
<Why it happened>

## Proposed Improvement
<What should change in the meta-project template>

## Generalization Argument
<Why this applies beyond this specific repo>

## Affected Template Components
<Which template files or skills would change>

## Evidence
<Links to session reviews, run-log entries, or other evidence>
```

### Forwarding Threshold

A lesson qualifies for forwarding when ALL of these hold:

1. The issue is not caused by project-specific configuration or content.
2. The proposed fix would change a template file, skill doc, or policy doc.
3. The issue would likely recur in other amplified repos.
4. The fix does not require project-specific knowledge to apply.

## Step 5: Update Failure Modes

If a new failure pattern was identified that is not already in `.agents/improvement/failure-modes.md`, add it. Each entry should include: the failure pattern name, symptoms, root cause, and mitigation.

## Approval Boundary

You may create review artifacts, local proposals, and forward lessons without user approval.

You may **not** apply changes to these files based only on self-review:

- Policy docs (`.agents/policy/`)
- Process docs (`.agents/bootstrap/`, `.agents/adapters/`)
- Workflow templates (`.agents/workflows/*-template.md`)
- Reading paths (`.agents/bootstrap/reading-paths.md`)
- Skill docs (`.agents/skills/`)

These require explicit user approval. Propose the change in a local proposal and wait.

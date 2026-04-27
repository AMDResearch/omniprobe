# Failure Modes

Record recurring process failures here when they matter beyond a single session. Use the structured format below. Assign each failure mode a unique ID (FM-1, FM-2, etc.).

## Entry Format

```markdown
## FM-N: <title>
- **Observed**: <date>
- **Description**: <what happened>
- **Impact**: <consequence>
- **Mitigation**: <what to do differently>
```

## Known Patterns

<!-- Add entries below as they are identified during session reviews. -->

## FM-1: Contract modification without approval
- **Observed**: template example
- **Description**: Agent changed acceptance criteria instead of reporting a blocker.
- **Impact**: Contract integrity violated; user trust eroded.
- **Mitigation**: Stop and report blocker. Proposed changes go in `handoff.md` under `Proposed Spec Changes`.

## FM-2: Excessive PM loading
- **Observed**: template example
- **Description**: Agent loaded far more PM than the task required.
- **Impact**: Context exhaustion; slower execution; irrelevant information competing with task-relevant context.
- **Mitigation**: Use `pm-load` for minimal relevant unit set. Load only what the current task needs.

## FM-3: Premature workflow execution
- **Observed**: template example
- **Description**: Workflow packet began execution before the contract was autonomy-ready.
- **Impact**: Work done against incomplete or ambiguous criteria; rework likely.
- **Mitigation**: Run `workflow-readiness-check` before transitioning from `draft` to `active`.

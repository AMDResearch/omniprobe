# Failure Modes

Record recurring process failures here when they matter beyond a single session. Use the structured format below.

## Identifiers

A bare `FM-<n>` belongs to the **framework's** namespace; record **this project's** own modes as
`FM-L<n>`, numbered from 1 within this repository. So `FM-L1` is the first mode this project
discovered.

The two namespaces cannot collide: a bare id always has a digit immediately after the hyphen, so a
sweep for framework ids cannot see a local one.

**Across repositories, qualify the id** — `omniprobe:FM-L1`. A bare local id is not globally
meaningful on purpose, which forces the qualifier at the one moment it matters. Framework ids need
no qualifier; there is only one framework.

**Why this exists, and why it is stated here rather than assumed.** Without the rule, "the next
unique ID in this file" means the next number in the *framework's* sequence — and since the
template ships three example entries, every project's first discovery lands on `FM-4` and means
something different in every project. **That is exactly what happened here.** This project's
`FM-4` (stale build-environment state, 2026-07-13) collided with the framework's `FM-4`
(unverified inference stated as established fact). Renamed to `FM-L1` on 2026-08-25.

> **Note on this section, added 2026-08-25.** It is copied from the framework template as of that
> date. This file is a *preserved* state file: an upgrade never overwrites it, which protects the
> entries below — and equally means this section will **not** be refreshed when the framework
> revises it. Treat it as a dated snapshot, and check the template if the convention seems to have
> moved.

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

> **FM-1 to FM-3 below are the framework's, not this project's.** They are the template's three
> example entries, unmodified — verified 2026-08-25 as byte-identical to the framework's own
> FM-1..FM-3. The framework has since grown to FM-13; this file does not carry FM-4..FM-13, because
> preservation stops an upgrade refreshing it. Read the framework's own
> `.agents/improvement/failure-modes.md` for the full set.

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

## FM-L1: Stale local build-environment state
- **Observed**: 2026-07-13
- **Renamed**: 2026-08-25, from `FM-4`. It collided with the framework's `FM-4` ("Unverified
  inference stated as established fact"), which meant this id resolved to two different things
  depending on which repository the reader was in. Content unchanged.
- **Description**: Long-lived local build artifacts (cloned repos, LLVM mirrors, install directories) accumulate stale configuration — broken remote URLs, wrong checked-out commits, leftover directories that block fresh clones. Build scripts may not validate these preconditions, causing silent failures or cascading errors discovered only at build time.
- **Impact**: Multiple rebuild cycles wasted; diagnosis time for each failure; proxy/network interruptions compound the problem since each retry re-encounters the same stale state.
- **Mitigation**: Before starting a build that depends on a local mirror or prior install, verify key preconditions: (1) git remote URLs point to valid upstreams, (2) expected commit hashes match `git rev-parse HEAD`, (3) target directories are absent or in expected state. Report mismatches as blockers rather than proceeding optimistically.

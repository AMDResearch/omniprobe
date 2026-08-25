# Guardrails

## Workspace Boundaries

- Work only inside the current repository unless the user explicitly asks otherwise.
- Treat `.agents/` as tracked project infrastructure.
- Treat `.untracked/` as local review and scratch space.

## Git Discipline

- Commit meaningful units of work with descriptive messages.
- Do not force-push, rebase published branches, or reset shared history without explicit user approval.
- Do not commit secrets, credentials, or large binary files.
- Do not delete branches that other workflows or agents may depend on.
- When in doubt about a destructive git operation, ask the user first.

## Scope Discipline

- Use workflow packets for substantial work.
- Preserve contract-controlled sections after a workflow becomes active.
- Stop when the requested outcome cannot be met under the current contract.
- Before running in parallel with other agents, check `.agents/state/active-workflows.md` and avoid uncoordinated write-scope overlap.
- Do not write outside the dossier's declared scope without declaring the expansion first. Whether that needs approval depends on which kind of change it is — see below.

### Scope amendment versus contract change

Widening a write scope and weakening an acceptance criterion are not the same risk, and this
policy used to treat them as if they were.

**Weakening, redefining or substituting an acceptance criterion is a contract change.** Stop
and get approval before proceeding. It *destroys* evidence: it changes what "done" means and
leaves no trace in the finished artifact, so a later reader cannot tell that the bar moved.

**Widening a declared write scope is a scope amendment.** It may proceed once it is declared
in the dossier's `write-scope` block and logged in `handoff.md` under `## Scope Amendments`
and in `run-log.md`. It *adds* evidence: one line in a tracked file, visible in the diff, and
the gate that caught it keeps catching everything else. Reviewed after the fact, not before.

The asymmetry is the point. An acceptance criterion can be written abstractly — "the new doc
is reachable from an existing docs index" — and often should be, because the path that
satisfies it is not known when the packet is specified. A write scope cannot be abstract; it
has to name paths. Nothing reconciles the two, so a binary gate blocks unforeseen *right*
turns exactly as firmly as wrong ones, and "specify harder up front" is not available as a
general fix. Four instances of that are on record.

An amendment is still bounded by the stop conditions below. In particular, widening into a
region another active workflow has claimed is a **write-scope collision** and stops, because
the risk there is two agents overwriting each other rather than one agent exceeding its brief.

## Context Hygiene

- Load only the PM units, workflow files, and documentation relevant to the current task.
- Do not front-load the entire PM index, all workflow packets, or all skill docs at session start.
- Use `pm-load` to select the minimal relevant unit set.
- When resuming a workflow, read `handoff.md` and `dossier.md` first. Read `run-log.md` only when execution history is specifically needed.
- If context is growing too large, summarize what you know and drop the source material rather than carrying everything forward.

## Verification Expectations

- Verify meaningful changes by running relevant tests, linters, or manual checks.
- Record verification outcomes in the workflow `run-log.md` or session capture.
- If work is unverified, say so explicitly in `handoff.md` and `run-log.md`.
- Do not mark acceptance criteria as met without verification evidence.

## Delegation Guidance

- When delegating work to a sub-agent or parallel session, provide the workflow packet as the contract. Do not rely on verbal instructions alone.
- Each delegated unit of work should have its own workflow packet with a distinct write scope.
- The delegating agent is responsible for checking `active-workflows.md` for overlap before assigning parallel work.
- Sub-agents follow the same guardrails as the primary agent.

## PM Expectations

- Update PM only with durable project knowledge.
- Do not turn PM into a transcript archive.
- Filter for durability before writing: will a fresh session 2 weeks from now benefit from this?
- Update `pm-current-state.md` when the project-wide situation changes materially.

## State Persistence

- Update `handoff.md` and `run-log.md` incrementally after every significant step, not at end-of-session.
- If you have completed 3 or more meaningful steps without updating `handoff.md` or `run-log.md`, stop current work and update state files before continuing.
- If you estimate you are approaching context limits, immediately update `handoff.md` and `run-log.md` before continuing.

## Checkpoint Protocol

Checkpoints are lightweight state saves — update `handoff.md` with current status and append
an entry to `run-log.md`. Each checkpoint should take under one minute. Checkpoint at these
triggers:

- After completing (or determining you cannot complete) an acceptance criterion.
- After creating or modifying more than three files since the last checkpoint.
- After running verification (tests, linters, manual checks) regardless of outcome.
- Before any operation you expect to take more than five minutes.
- When context usage is above ~75% — checkpoint before the system compresses prior messages.

Checkpoints supplement the incremental persistence rules in State Persistence above. They
exist so that if the session ends unexpectedly, the next session can pick up from the last
checkpoint rather than replaying the entire session's work.

## Stop Conditions

- **Contract violation**: If you realize you are weakening, redefining or substituting an acceptance criterion, or changing the failure policy, without user approval, stop immediately and report. Widening a declared write scope is a **scope amendment**, not a contract change — declare it, log it, and proceed (see Scope Discipline above).
- **Unresolvable blocker**: If a dependency cannot be met and the failure policy is `stop`, move the workflow to `failed/` and report.
- **Write-scope collision**: If your intended write scope collides with another active workflow without explicit coordination, stop and ask the user.
- **Safety risk**: If the requested work could cause data loss, security vulnerabilities, or irreversible damage, stop and confirm with the user.
- **Uncertainty**: If you are unsure whether an action is within scope or safe, stop and ask rather than proceeding.

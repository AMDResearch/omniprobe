# Guardrails

## Workspace Boundaries

The omniprobe workspace is:
  `/work1/amd/rvanoo/repos/omniprobe` (and its mirror at `/home1/rvanoo/repos/omniprobe`)

- You MAY read any file on the system (for research, understanding dependencies, etc.).
- You MUST NOT write, edit, delete, or move any file outside the omniprobe workspace.
- Exception: you may use existing temporary directories (`/tmp`, `/var/tmp`) for scratch files,
  but clean up after yourself.
- Treat `.agents/` as tracked project infrastructure.
- Treat `.untracked/` as local review and scratch space.

## Git Discipline

### Commit after every step
- After completing each logical step of work, create a commit immediately.
- Keep commits small and atomic — one concern per commit.
- Do NOT batch multiple steps into a single commit.

### Branch safety
- Use feature branches for substantial work (features, refactors, multi-step implementations)
  where intermediate commits could leave main in an unstable state.
- Quick, atomic changes may be committed directly to main when each commit is self-contained
  and leaves the project stable.
- Do not merge feature branches into main unless the user explicitly instructs you to.

### No destructive git operations
- No force-push (`--force`, `--force-with-lease`)
- No `git reset --hard`
- No branch deletion (`git branch -D`, `git push --delete`)
- No amending of commits that have been pushed
- Do not push to any remote unless explicitly instructed by the user.
- Do not commit secrets, credentials, or large binary files.

## Build and Runtime Safety

- Do not install or uninstall system packages.
- Do not modify files under `/opt`, `/usr`, `/etc`, or any system directory.
- Do not modify user dotfiles (`~/.bashrc`, `~/.profile`, etc.) or user-level configs
  outside the workspace.
- Do not run commands that kill other users' processes.
- Do not run resource-intensive commands (stress tests, large builds) without mentioning it first.

## Scope Discipline

- Use workflow packets for substantial work.
- Preserve contract-controlled sections after a workflow becomes active.
- Stop when the requested outcome cannot be met under the current contract.
- Before running in parallel with other agents, check `.agents/state/active-workflows.md`
  and avoid uncoordinated write-scope overlap.
- Do not expand scope beyond what the dossier specifies. Note proposed expansions in
  `handoff.md` under `Proposed Spec Changes`.
- Do not refactor, reformat, or "improve" code that is not part of the current task.
- If you discover something that needs fixing but is out of scope, note it in your output —
  do not fix it yourself.

## Context Hygiene

- Load only the PM units, workflow files, and documentation relevant to the current task.
- Do not front-load the entire PM index, all workflow packets, or all skill docs at session start.
- Use `pm-load` to select the minimal relevant unit set.
- When resuming a workflow, read `handoff.md` and `dossier.md` first. Read `run-log.md` only
  when execution history is specifically needed.
- If context is growing too large, summarize what you know and drop the source material.

### Delegate to sub-agents
Use sub-agents (the Agent tool) for work that is research-heavy or produces large output.
This keeps the main context clean for decision-making and editing.

Good candidates for sub-agents:
- Exploring unfamiliar code ("find all callers of X", "how does Y work?")
- Searching for all usage sites of a function/type being refactored
- Running tests and analyzing failures
- Investigating whether a change broke something in an unrelated area
- Reading large files or many files to understand a subsystem

Keep in the main context: actual code edits, progress tracking, approach decisions,
cross-cutting concerns.

When launching a sub-agent that can write files, include workspace boundary, git,
scope, and build safety rules in the prompt.

## Verification Expectations

- Verify meaningful changes by running relevant tests, linters, or manual checks.
- Record verification outcomes in the workflow `run-log.md` or session capture.
- If work is unverified, say so explicitly in `handoff.md` and `run-log.md`.
- Do not mark acceptance criteria as met without verification evidence.

## Delegation Guidance

- When delegating work to a sub-agent or parallel session, provide the workflow packet
  as the contract. Do not rely on verbal instructions alone.
- Each delegated unit of work should have its own workflow packet with a distinct write scope.
- The delegating agent is responsible for checking `active-workflows.md` for overlap.
- Sub-agents follow the same guardrails as the primary agent.

## PM Expectations

- Update PM only with durable project knowledge.
- Do not turn PM into a transcript archive.
- Filter for durability before writing: will a fresh session 2 weeks from now benefit from this?
- Update `pm-current-state.md` when the project-wide situation changes materially.

## State Persistence

- Update `handoff.md` and `run-log.md` incrementally after every significant step,
  not at end-of-session.
- If you have completed 3 or more meaningful steps without updating `handoff.md` or
  `run-log.md`, stop current work and update state files before continuing.
- If you estimate you are approaching context limits, immediately update `handoff.md`
  and `run-log.md` before continuing.

## Checkpoint Protocol

Checkpoints are lightweight state saves — update `handoff.md` with current status and append
an entry to `run-log.md`. Each checkpoint should take under one minute. Checkpoint at these
triggers:

- After completing (or determining you cannot complete) an acceptance criterion.
- After creating or modifying more than three files since the last checkpoint.
- After running verification (tests, linters, manual checks) regardless of outcome.
- Before any operation you expect to take more than five minutes.
- When context usage is above ~75% — checkpoint before the system compresses prior messages.

## Stop Conditions

- **Contract violation**: If you realize you are changing acceptance criteria, scope, or
  failure policy without user approval, stop immediately and report.
- **Unresolvable blocker**: If a dependency cannot be met and the failure policy is `stop`,
  move the workflow to `failed/` and report.
- **Write-scope collision**: If your intended write scope collides with another active workflow
  without explicit coordination, stop and ask the user.
- **Safety risk**: If the requested work could cause data loss, security vulnerabilities,
  or irreversible damage, stop and confirm with the user.
- **Uncertainty**: If you are unsure whether an action is within scope or safe, stop and ask
  rather than proceeding.

## When in Doubt

- If an action feels risky or ambiguous, stop and explain what you want to do and why.
- Prefer doing less over doing too much.
- However, the ideal is for you to work unmonitored. If there is no strong reason to stop,
  continue. Don't stop just because you reached the end of a major step; if everything
  looks good, continue with the next step.

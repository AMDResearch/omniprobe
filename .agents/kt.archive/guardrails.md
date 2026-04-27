# Guardrails for --dangerously-skip-permissions sessions

Read this file at the start of every session that uses
`--dangerously-skip-permissions`. These rules are non-negotiable.

## 1. Workspace boundary

The omniprobe workspace is:
  /work1/amd/rvanoo/repos/omniprobe   (and its mirror at /home1/rvanoo/repos/omniprobe)

- You MAY read any file on the system (for research, understanding dependencies, etc.)
- You MUST NOT write, edit, delete, or move any file outside the omniprobe workspace.
- Exception: you may use existing temporary directories (/tmp, /var/tmp) for scratch files,
  but clean up after yourself.

## 2. Git discipline

### Commit after every step
- After completing each logical step of work, create a commit immediately.
- Keep commits small and atomic — one concern per commit.
- This allows easy rollback if a step turns out to be wrong.
- Do NOT batch multiple steps into a single commit.

### Branch safety
- Use feature branches for substantial work (features, refactors, multi-step
  implementations) where intermediate commits could leave main in an unstable
  state.
- Quick, atomic changes (deleting a file, updating a skill, small config edits)
  may be committed directly to main when each commit is self-contained and
  leaves the project stable.
- Do not merge feature branches into main unless the user explicitly instructs
  you to do so.
- When in doubt about whether work warrants a feature branch, ask.

### No destructive git operations
- No force-push (--force, --force-with-lease)
- No git reset --hard
- No branch deletion (git branch -D, git push --delete)
- No amending of commits that have been pushed
- Do not push to any remote unless explicitly instructed by the user.

## 3. Build and runtime safety

- Do not install or uninstall system packages.
- Do not modify files under /opt, /usr, /etc, or any system directory.
- Do not modify user dotfiles (~/.bashrc, ~/.profile, etc.) or user-level
  configs outside the workspace.
- Do not run commands that kill other users' processes.
- Do not run resource-intensive commands (stress tests, large builds) without
  mentioning it first in your output.

## 4. Scope discipline

- Stay focused on the task described in the current work item or refactor dossier.
- Do not refactor, reformat, or "improve" code that is not part of the
  current task, even if you notice opportunities.
- Do not add features, documentation, or tests beyond what the task requires.
- If you discover something that needs fixing but is out of scope, note it
  in your output for the user — do not fix it yourself.

## 5. Verification

- At the start of the session, print a short confirmation that you have read
  and will follow these guardrails.
- After each commit, run a quick sanity check (e.g., does it still build?)
  before moving on to the next step.

## 6. Context management — use sub-agents for heavy lifting

Lengthy refactors generate a lot of context (file reads, diffs, build output, test
results). As the context window fills, earlier messages get compressed and you lose
track of the overall plan, prior decisions, or what you've already changed.

### Delegate to sub-agents
Use sub-agents (the Agent tool) for work that is research-heavy or produces large
output. This keeps the main context clean for decision-making and editing.

Good candidates for sub-agents:
- Exploring unfamiliar code ("find all callers of X", "how does Y work?")
- Searching for all usage sites of a function/type being refactored
- Running tests and analyzing failures
- Investigating whether a change broke something in an unrelated area
- Reading large files or many files to understand a subsystem

### Keep in the main context
The following should stay in the main conversation, NOT be delegated:
- The actual code edits and modifications
- Tracking progress through the dossier steps
- Decisions about approach and design
- Cross-cutting concerns that span multiple steps

### Practical guidelines
- If a research task will require reading more than ~5 files, use a sub-agent.
- Give sub-agents clear, self-contained prompts with enough context to work
  independently — they cannot see the main conversation history unless you
  tell them what they need to know.
- When a sub-agent returns, summarize its findings concisely in the main context
  rather than repeating everything verbatim.
- Launch independent sub-agents in parallel when possible (e.g., researching
  two different subsystems simultaneously).

### Pass guardrails to sub-agents
Sub-agents do NOT inherit the main conversation context. They will pick up
CLAUDE.md (since they run in the same repo), but this guardrails file is
separate and must be communicated explicitly.

When launching a sub-agent that can write files or run commands (i.e., a
general-purpose agent), include these rules in the prompt:
- Workspace boundary: no writes outside the omniprobe workspace
  (/work1/amd/rvanoo/repos/omniprobe and /home1/rvanoo/repos/omniprobe,
  plus ~/repos/triton and ~/repos/sandbox).
- Git: no destructive git ops, no commits to main, no pushing.
- Scope: do not fix or improve things outside the task.
- Build safety: no system modifications, no package installs.

Read-only sub-agents (Explore, Plan) are lower risk since they cannot edit
files, but still include the workspace boundary rule if they run Bash commands.

## 7. When in doubt

- If an action feels risky or ambiguous, stop and explain what you want to do
  and why. Let the user decide.
- Prefer doing less over doing too much. It is always safer to stop early
  and ask than to proceed and cause damage.
  However, the ideal is for you to work unmonitored. If there is no strong
  reason to stop, don't ask for permission, but continue. Don't stop just
  because you reached the end of a major step; if everything looks good,
  continue with the next major step.

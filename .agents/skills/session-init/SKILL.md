---
name: session-init
description: |
  Bootstrap a new agent session. Use at the start of every conversation or when
  the user says "start session", "init", or "begin". Reads project metadata,
  identifies active workflows, detects prior aborted sessions, and produces a
  concise briefing so the agent can begin work with minimal context loading.
---

# session-init

## Purpose

This is the canonical session entry point. It reads project metadata, identifies the current focus and active workflows, determines what else the agent needs to load, and produces a concise briefing. The goal is to load the least material that lets the agent act correctly -- not to front-load everything.

## Preconditions

- The `.agents/` directory exists in the repository root.
- `.agents/project.json` exists (created by `amplify`).

## Required Reads

Read these files in order. Stop and report if any file marked [required] is missing.

1. `.agents/project.json` [required] -- project name, type, adapter.
2. `.agents/adapters/shared-entrypoint.md` [required] -- cross-adapter policies.
3. `.agents/policy/guardrails.md` [required] -- workspace boundaries, scope discipline, stop conditions.
4. `.agents/policy/contract.md` -- contract preservation rules.
5. `.agents/policy/verification.md` -- verification expectations.
6. `.agents/state/current-focus.md` [required] -- what the last session left for this one.
7. `.agents/state/active-workflows.md` [required] -- all in-flight workflows and their owners.
8. `.agents/bootstrap/reading-paths.md` -- load-path guidance for different session types.
9. `.agents/pm/pm-index.md` -- unit registry (scan headers only; do not read full units yet).

## Procedure

1. **Read project metadata.** Parse `project.json` for project name and adapter type. Confirm the adapter file exists at `.agents/adapters/<adapter>.md`.
   If `project.json` contains `"sidecar": true`, this is a sidecar workspace. Note the
   `target_repo` path. In sidecar mode, verify the target repo exists and is accessible.
   If the target repo is not found, add a warning: "Sidecar target repo not found at
   <path>. The agent may not be able to access the project codebase."
2. **Read shared entrypoint.** Note any session-level policies or constraints.
3. **Read policy documents.** Read `guardrails.md` (required). Read `contract.md` and `verification.md`. Note workspace boundaries, stop conditions, and contract rules. Acknowledge policy ingestion in the briefing.
4. **Read current focus.** Extract: the recommended next action, any blockers noted by the prior session, and any workflow IDs referenced.
5. **Read active workflows.** Build a list of workflows with their state (active, blocked, suspended) and ownership. Identify which workflows are unowned and available. For each active workflow ID, the packet directory is at `.agents/workflows/<state>/<workflow-id>/`. Verify the directory exists.
6. **Reconcile state.** Perform a lightweight state check:
   a. For each workflow listed as `active`, `blocked`, or `suspended` in `active-workflows.md`,
      verify the directory `.agents/workflows/<state>/<workflow-id>/` exists. If it does not,
      check other lifecycle directories for a match. Report any mismatches in the briefing as
      warnings: "State inconsistency: <workflow-id> listed as <state> but found in <actual-dir>
      (or not found)."
   b. For each directory found under `.agents/workflows/active/`, verify it has a matching row
      in `active-workflows.md`. Report orphan directories.
   c. If any inconsistencies are found, add to the briefing:
      "Run `/state-check` for a full reconciliation before starting work."
   d. If contradictions exist between `current-focus.md` and `active-workflows.md` (e.g.,
      one says a workflow is active while the other says done), trust the directory location
      as ground truth and note the contradiction.
   e. Check `pm-index.md` against files in `.agents/pm/units/`. If the counts differ,
      add to the briefing: "PM index may be out of sync with unit files on disk.
      Consider running `/pm-validate`."
7. **Detect signs of a prior aborted session.** Check for indicators that the previous
   session ended without running `/session-close`:

   a. **Session-active marker.** Check if `.agents/state/session-active.md` exists. If it
      does, a prior session started but did not close cleanly. Read the marker to see when
      the prior session started. Add to the briefing: "Prior session (started <timestamp>)
      did not close cleanly. Recovery recommended."
   b. **Uncommitted changes.** Run `git status --short`. If there are uncommitted changes,
      add to the briefing: "Uncommitted changes detected in the worktree. A prior session
      may have been interrupted, or these may be intentional edits." This is informational,
      not a warning — the user may have edited files between sessions.
   c. **Stale handoffs.** For each active workflow, compare the modification timestamp of
      `handoff.md` against the most recent file modification in the workflow's write scope
      (from the dossier metadata). If source files are newer than the handoff, flag:
      "Handoff for <workflow-id> may be stale — source files were modified more recently."
   d. **Missing session capture.** Check whether the most recent file in
      `.untracked/session-captures/` is older than the most recent commit (use `git log -1
      --format=%ct`). If commits exist without a corresponding capture, flag: "Recent
      commits have no session capture — a prior session may have ended without
      `/session-close`."
   e. **Recovery recommendation.** If any of (a)-(d) triggered, add to the briefing:
      "Suggested recovery: (1) review uncommitted changes with `git diff`, (2) update
      handoff.md for any active workflow, (3) run `/session-capture` for the interrupted
      session, (4) proceed with current session."
   f. **Remove stale marker.** If the session-active marker exists from a prior session,
      remove it now. A fresh marker will be written in step 14.

8. **Check for unpushed commits.** Run
   `git rev-list --left-right --count <upstream>...HEAD` and report any unpushed commits in the
   briefing. If the repository has no upstream configured, say so and move on; that is a fact
   about the repository, not a fault.

   **The briefing is the only place this belongs.** The count is a claim about present state and
   is false the moment anyone pushes, so it is warned about here and never written to a tracked
   file — see `session-close` step 5d for the loop that rule exists to stop. Reporting it at
   session start is what makes the rule affordable: the fact stays available to whoever needs it,
   at the one moment it is both true and actionable.

9. **Resolve declared plugins.** Run `.agents/hooks/resolve-plugins.sh` and include its output in
   the briefing verbatim as the `Plugins:` line. If it prints nothing, **omit the line entirely** —
   no plugins are declared, which is the default and the common case, and an empty `Plugins:` line
   would be a change every repository sees in return for nothing.

   The hook reads `project.json`, resolves each declared path, and reports each plugin's
   `amplify_version` and active-workflow count. See `docs/usage/plugins.md` for the format.

   **Do not reimplement this by reading `project.json` yourself.** The point of the hook is that
   the reported facts expire — a version moves, a workflow completes — so they are derived at read
   time and written to no tracked file, the same discipline as `Unpushed:` in step 8. A plugin that
   does not resolve is reported and the session continues; it is never a reason to stop.

10. **Recommend skills based on context.** Based on what was discovered during state reading,
   include relevant skill recommendations in the briefing:

   - If the last session capture is more than 2 days ago (check file dates in
     `.untracked/session-captures/`): recommend `/state-check` — "It has been >2 days
     since the last session. Run `/state-check` to verify state consistency."
   - If any PM unit's most recent `Last Verified` entry is older than 14 days: recommend
     `/pm-validate` — "Some PM units may be stale. Run `/pm-validate` to check." The field
     lives in the unit files under `.agents/pm/units/`, not in `pm-index.md`, and the section
     is an **append-only list** — take the maximum `- <YYYY-MM-DD>` date under the heading.
     Reading the first line reports every freshly-updated unit as months stale; this has
     produced a false briefing more than once.
   - If unreviewed session captures have accumulated (>= 5 captures since last review):
     recommend `/session-review` — "Multiple captures are unreviewed. Run `/session-review`
     in batch mode."
   - If resuming a workflow: recommend reading the workflow's handoff first via
     `/workflow-resume` — "Use `/workflow-resume <workflow-id>` for structured resumption."
   - If open feedback items exist (check `.untracked/feedback/feedback-index.md` if it
     exists): note "There are open feedback items that need triage."

   Include these recommendations in the briefing output under a new "Suggested actions:" line.
11. **Check run-log consistency (if resuming).** If resuming a workflow, read the run-log and compare against the handoff to identify any gaps. If the run-log has no entries but the handoff indicates work was done, note the gap in the briefing.
12. **Classify session type.** Based on the user's opening message (if any) and current-focus, determine the session type:
   - **Directed work**: user gave a specific task -- match it to an existing workflow or flag that a new one is needed.
   - **Workflow resume**: current-focus points to a specific workflow -- prepare to resume it.
   - **Open session**: no specific direction -- present the briefing and wait for instruction.
13. **Determine additional reads.** Based on session type:
   - Workflow resume: queue the packet's `handoff.md` and `dossier.md` for immediate reading. Queue relevant PM units listed in the dossier's metadata.
   - Directed work on an existing workflow: same as resume.
   - New work: queue `pm-current-state.md` for context.
   - Open session: no additional reads yet.
14. **Produce briefing.** Output a summary to the user (not a file) containing:
   - Project name and adapter.
   - Current focus summary (1-2 sentences).
   - Active workflow count and any that are blocked or unowned.
   - What the agent will read next and why.
   - Any blockers or warnings from prior sessions.

## Output

The briefing is delivered as a direct response to the user, not written to a file. Format:

```
Session initialized for <project-name>.

Policies loaded: guardrails, contract, verification
Mode: <standard | sidecar (target: <target-repo-path>)>
Focus: <current focus summary>
Active workflows: <count> (<blocked count> blocked, <unowned count> unowned)
Session type: <directed | resume | open>

State: <consistent | N inconsistencies found — run /state-check>
Recovery: <prior session did not close cleanly — see recovery steps | clean>
Unpushed: <N commits not on <upstream> | fully pushed | no upstream configured>
Plugins: <verbatim output of .agents/hooks/resolve-plugins.sh — omit the line entirely when it prints nothing>
Suggested actions: <list of recommended skills with brief reasons, or "none">
Next reads: <list of files the agent will read>
Blockers: <any, or "none">

Reminder: update handoff.md and run-log.md incrementally. Run /session-capture before ending.
```

In sidecar mode, additionally include after the "Mode:" line:
- Target repo git status (branch, clean/dirty)
- Whether the target repo has an existing `AGENTS.md` (and note that it is the target's
  own file, not the framework's)
- A reminder that code changes go in the target repo and framework changes stay in the sidecar

After delivering the briefing, write the session-active marker file at
`.agents/state/session-active.md` with content:

```
Session started: <current timestamp>
```

This marker is removed by `/session-close`. If it is still present at the next
`/session-init`, it indicates this session did not close properly.

Then immediately read the files listed under "Next reads."

Before concluding the briefing, remind the user and note to self: `handoff.md` and `run-log.md` must be updated incrementally throughout the session, not deferred to session end. Run `/session-capture` before ending work.

## Completion Criteria

- All [required] files have been read.
- The agent has classified the session type.
- The briefing has been delivered to the user.
- Additional context files (handoff, dossier, PM units) have been read if applicable.
- The agent is ready to begin work or await user direction.

## Error Handling

- If `.agents/project.json` is missing, stop: "Project not initialized. Run amplify to set up .agents/ first."
- If `current-focus.md` is empty or contains only placeholder text, treat it as an open session and note: "No focus set by prior session."
- If `active-workflows.md` references workflow directories that do not exist, report the dangling references and continue.
- If the user's opening message conflicts with `current-focus.md`, prefer the user's explicit instruction and note the divergence.

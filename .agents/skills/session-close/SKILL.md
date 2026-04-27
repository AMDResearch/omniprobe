---
name: session-close
description: |
  Perform the full end-of-session sequence. Use when the user says "close",
  "wrap up", "done for now", "session-close", or similar. Updates workflow
  documents, persists PM knowledge, commits changes in logical groups, runs
  session-capture, and delivers a summary.
---

# session-close

## Purpose

This skill bundles all end-of-session housekeeping into a single invocation. Without it,
the user must manually instruct PM updates, workflow document updates, commits, and session
capture — a sequence that is the same every time and easy to skip or partially complete.

## Preconditions

- A work session is ending (the user says "close", "wrap up", "session-close", or similar).
- The agent has context about what was done during the session.

## Required Reads

1. `.agents/state/active-workflows.md` — identify which workflow(s) were touched.
2. `.agents/pm/pm-index.md` — know which PM units exist.
3. If a workflow was active: the workflow's `handoff.md` and `run-log.md`.

## Procedure

1. **Update workflow documents.** For each workflow touched during this session:
   a. Ensure `run-log.md` has entries covering all meaningful work done this session. If
      the last run-log entry is stale (does not cover recent work), append a catch-up entry.
   b. Update `handoff.md` with current status, the next exact step, and any new risks or
      blockers discovered.
   c. If the workflow is complete (all acceptance criteria met), run the `workflow-complete`
      procedure (see `.agents/skills/workflow-complete/SKILL.md`).

2. **Update Project Memory.** Run the `pm-update` procedure:
   a. Filter for durable knowledge learned this session.
   b. Update affected PM units (including code-navigation units if source files changed).
   c. Update `pm-current-state.md` with any changed work areas, risks, or workflow states.
   d. Record any decisions made to `pm-decisions.md`.
   e. Record any new terminology to `pm-glossary.md`.
   f. Update `pm-index.md` if units were created or changed.

3. **Update state files.** Ensure `current-focus.md` and `active-workflows.md` reflect the
   current project state. If a workflow completed, apply the archival steps from
   `workflow-complete`.

4. **Commit changes in logical groups.** Stage and commit changes with clear, descriptive
   messages. Group logically:
   - Source code changes: one or more commits covering the implementation work.
   - Workflow document updates (run-log, handoff, dossier state changes): one commit.
   - PM updates: one commit.
   - State file updates: may be combined with workflow or PM commit if small.

   Use conventional commit messages that reference the workflow ID where applicable
   (e.g., "ft_feature-name: implement phase 2 acceptance criteria").
   Do not force-push or amend prior commits.

   Skip/caution rules:
   - If the worktree contains staged or unstaged changes unrelated to the current session's
     work, do not bundle them. Commit only changes the agent made or can confidently
     attribute to this session.
   - If logical commit boundaries are unclear (e.g., a large refactor with interleaved
     source and test changes), ask the user how they want commits grouped rather than
     guessing.
   - If the user has not indicated that commits are desired in this session's context,
     skip the commit step and note: "Uncommitted changes remain. Commit when ready or
     run `/session-close` again after review."
   - Never force-push or amend prior commits during session-close.

5. **Run session-capture.** Follow the `session-capture` procedure
   (see `.agents/skills/session-capture/SKILL.md`) to create a normalized session record.
   This includes the review cadence check — if enough captures have accumulated, the
   capture will recommend running `/session-review`.

6. **Deliver summary.** Report to the user:
   - What was committed (brief list of commit messages).
   - Workflow state changes (any completions, new blockers).
   - PM updates made (units touched, decisions recorded).
   - Whether a session review is recommended.
   - The session capture file path.

7. **Remove session-active marker.** Delete `.agents/state/session-active.md`. This signals
   to the next `/session-init` that this session closed properly. This is the last action
   in the close sequence.

## Output

No single output file. This skill orchestrates updates across multiple files:
- Workflow `run-log.md` and `handoff.md` (and `dossier.md` if completing).
- PM files (`pm-current-state.md`, units, `pm-decisions.md`, `pm-glossary.md`, `pm-index.md`).
- State files (`current-focus.md`, `active-workflows.md`).
- Git commits.
- Session capture file at `.untracked/session-captures/<timestamp>-<agent>.md`.

## Completion Criteria

- All active workflow documents are up to date (run-log, handoff).
- PM has been updated with any durable knowledge from this session.
- State files reflect current project state.
- All changes are committed with descriptive messages.
- A session capture file has been written.
- The user has received a summary of what was done.

## Error Handling

- If no meaningful work was done this session (nothing to commit, no state changes), still
  produce a minimal session capture noting "No significant work this session" and skip the
  commit step.
- If a commit fails (e.g., pre-commit hook), report the failure and the error message. Do
  not skip the remaining steps — continue with session capture even if commits fail.
- If PM update encounters missing index or units, note the inconsistency in the session
  capture and recommend running `/pm-validate` next session.
- If the user interrupts mid-close (e.g., wants to do more work), stop the close sequence
  and resume normal operation. The user can re-run `/session-close` later.

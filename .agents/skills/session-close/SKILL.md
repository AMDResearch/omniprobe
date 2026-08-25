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

   **Sidecar mode (dual-repo commit):** If `project.json` contains `"sidecar": true`,
   commits must be split across two repositories:
   a. **Target repo commits:** Stage and commit code changes in the target repo directory
      (found at the `target_repo` path in `project.json`, relative to the sidecar). Use
      `git -C <target-repo-path>` to run git commands there.
   b. **Sidecar repo commits:** Stage and commit framework state changes (`.agents/`,
      workflows, PM, state files) in the sidecar directory (the CWD).
   c. Commit the target repo first, then the sidecar, so the sidecar handoff can reference
      the target's commit hash if needed.
   d. If no code changes were made in the target repo, skip the target commit.

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

5. **Run the repository's outbound-content scan, if it has one.** Some repositories keep a
   script checking what a push would publish against a project-specific policy; most have
   none and skip this step entirely.

   **Run it only if both `scripts/leak-scan.sh` exists and `$AMP_DEC6_PATTERN` is set.** That
   variable holds the scan's pattern list, kept in the environment rather than the repository
   because a denylist enumerates precisely what it protects. Unset therefore means this
   repository has not configured such a policy and there is nothing here to check — the step
   is inert, so do nothing and say nothing about it in the summary. Do not invent a policy for
   a repository that has not declared one, or treat a missing script as a finding.

   When both hold, resolve the range's two ends to commit ids *before* scanning —
   `git rev-parse <upstream> HEAD` — run `scripts/leak-scan.sh <base>..<head>`, and:

   a. **Read the exit code directly** — never through a pipeline, which replaces the status
      you meant to read and once turned a failing scan into a reported `exit=0`.
   b. Record the census (commits, added lines, messages, tracked files) and the verdict under
      **Recent Decisions** in `.agents/state/current-focus.md`, dated. The census is what
      distinguishes a clean result from a scan that never ran, so record it even when clean.
   c. **Write the range as resolved commit SHAs**, never as a symbolic ref. The format is:

          scanned 4b75398..02df9cb (2 commits, 119 added lines, 617 tracked files, zero hits)

      A SHA range is permanently true and independently re-runnable by anyone, at any later
      time, on a repository whose branches have moved. The same sentence written as
      `rwvo/main..HEAD (2 commits ahead)` is false within minutes of the next push, and it
      invites the following session to "correct" it.
   d. **Write no claim about push state.** The census is evidence about a completed action and
      does not go stale; *n commits are unpushed*, or *the tree is fully pushed at `<sha>`*, is
      a claim about present state and is stale the moment anyone pushes. So:
      **no claim about push state is written to a tracked file.**
      The count of unpushed commits belongs in the step-7 summary, which is conversation and is
      not committed.

      This is not fastidiousness. The record is a loop that has run in two repositories: the
      close records *n* unpushed, the user pushes, the record is now wrong, someone corrects
      it, and the correction is itself a new unpushed commit. The commit that records a push
      necessarily follows the push, so the file can never be right at rest. Note the rule is
      stronger than "write the command rather than the count" — that still leaves a tracked
      paragraph whose subject is push state, and the evidence is that people kept editing it.
   e. Note in the entry that the commit carrying it is outside the range just scanned, so
      whoever pushes must **re-derive** the range at push time.
   f. Surface the census, the verdict, and the unpushed count in the step-7 summary.

   **This step does not block the close.** A non-zero exit is reported and the close
   continues; pushing is the user's action, and refusing to finish would only lengthen the
   post-close tail this step exists to shrink.

6. **Run session-capture.** Follow the `session-capture` procedure
   (see `.agents/skills/session-capture/SKILL.md`) to create a normalized session record.
   This includes the review cadence check — if enough captures have accumulated, the
   capture will recommend running `/session-review`.

7. **Deliver summary.** Report to the user:
   - What was committed (brief list of commit messages).
   - Workflow state changes (any completions, new blockers).
   - PM updates made (units touched, decisions recorded).
   - The outbound-content scan's census and verdict, if step 5 ran.
   - The number of unpushed commits, from `git rev-list --left-right --count <upstream>...HEAD`.
     Report it here and nowhere else: this summary is conversation, so it is allowed to state a
     fact that will be false after the user acts on it. A tracked file is not.
   - Whether a session review is recommended.
   - The session capture file path.

8. **Remove session-active marker.** Delete `.agents/state/session-active.md`. This signals
   to the next `/session-init` that this session closed properly. This is the last action
   in the close sequence.

   Note that work sometimes continues after this point — an interrupted close resumed later,
   or a push and its follow-up. Anything done after this step is outside the session by the
   framework's own definition: unmarked, absent from the capture just written, and invisible
   to the next `/session-init`'s recovery detection. Step 5 exists because the most common
   such tail was the scan itself. If other work lands after the close, amend the capture
   rather than leaving it describing a state that has stopped being true.

## Output

No single output file. This skill orchestrates updates across multiple files:
- Workflow `run-log.md` and `handoff.md` (and `dossier.md` if completing).
- PM files (`pm-current-state.md`, units, `pm-decisions.md`, `pm-glossary.md`, `pm-index.md`).
- State files (`current-focus.md`, `active-workflows.md`), including the scan entry under
  Recent Decisions when step 5 runs.
- Git commits.
- Session capture file at `.untracked/session-captures/<timestamp>-<agent>.md`.

## Completion Criteria

- All active workflow documents are up to date (run-log, handoff).
- PM has been updated with any durable knowledge from this session.
- State files reflect current project state.
- All changes are committed with descriptive messages.
- If the repository has an outbound-content scan and it is configured, it has been run, its
  exit code read directly, and its census and verdict recorded under Recent Decisions. If it
  has none, the step was skipped silently.
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

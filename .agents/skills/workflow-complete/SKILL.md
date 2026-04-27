---
name: workflow-complete
description: |
  Perform the full completion sequence for a finished workflow. Use when all
  acceptance criteria are met and the workflow is ready to move to done state.
  Updates dossier, writes final run-log and handoff entries, moves the packet
  directory, and archives the entry in active-workflows.md.
---

# workflow-complete

## Purpose

This skill ensures all completion steps are performed together when a workflow reaches `done` state. It prevents the common failure where a workflow is marked done in `active-workflows.md` but the packet directory is not moved, the run-log has no closing entry, or the handoff is stale.

## Preconditions

- A workflow packet exists in `.agents/workflows/active/<workflow-id>/` (or `blocked/`, `suspended/`).
- All acceptance criteria in `dossier.md` have been verified as met (or marked best-effort per failure policy).

## Required Reads

1. `.agents/workflows/<current-state>/<workflow-id>/dossier.md` [required] -- verify acceptance criteria status.
2. `.agents/workflows/<current-state>/<workflow-id>/handoff.md` [required] -- current state.
3. `.agents/workflows/<current-state>/<workflow-id>/run-log.md` -- execution history.
4. `.agents/state/active-workflows.md` [required] -- coordination index.
5. `.agents/state/current-focus.md` [required] -- project focus.

## Procedure

1. **Verify acceptance criteria.** Read `dossier.md` and confirm every acceptance criterion is marked as met with verification evidence. If any criterion is unmet and the failure policy is not `best_effort`, stop: "Cannot complete workflow — unmet criteria: [list]. Resolve or change failure policy first."
2. **Update dossier metadata.** Set the `Lifecycle State` field in `dossier.md` to `done`.
   Verify the update was written: re-read the `Lifecycle State` line from `dossier.md` and
   confirm it now says `done`. If it does not, stop and report the error.
3. **Write final run-log entry.** Append a closing entry to `run-log.md`:
   ```markdown
   ### <timestamp>

   - **Actor**: <agent identifier>
   - **Planned step**: Workflow completion
   - **Action taken**: All acceptance criteria verified. Workflow marked done.
   - **Result**: success
   - **Files touched**: dossier.md, handoff.md, active-workflows.md, current-focus.md
   - **Verification**: <summary of criteria verification>
   - **Criteria impact**: All criteria met
   - **Blocker / Risk**: none
   ```
4. **Write final handoff.** Update `handoff.md` with final status:
   - Current Status: **Done. All acceptance criteria met.**
   - Last Verified: <timestamp and summary>
   - Next Exact Step: N/A — workflow complete.
   - Active Risks / Blockers: none.
5. **Move the packet directory.** Relocate the entire workflow directory from `.agents/workflows/<current-state>/<workflow-id>/` to `.agents/workflows/done/<workflow-id>/`.
6. **Archive completed entry in active-workflows.md.** Move the workflow's row from the main
   table to a `## Completed` section at the bottom of the file. If the `## Completed` section
   does not exist, create it with a minimal table header (`| ID | Type | Completed |`). The
   archived row needs only the workflow ID, type, and completion date — strip the owner, write
   scope, dependencies, and blocker columns. If the Completed section exceeds 30 rows, remove
   the oldest rows (they remain discoverable via the `done/` directory).
7. **Prune current-focus.md.** Remove this workflow from "Current Focus Areas" and
   "Active Workflows" sections entirely. If this workflow appears in "Recent Decisions"
   only as a completion notice (not a substantive decision), remove that entry too.
   Add a one-line entry to "Recent Decisions" only if a durable project decision was made
   during this workflow (technology choice, architecture decision, scope decision). Keep
   the total "Recent Decisions" section under 15 entries by removing the oldest
   non-architectural entries when the limit is reached.
8. **Verify state consistency.** After completing all updates, perform a quick check:
   - Confirm the workflow directory is now at `.agents/workflows/done/<workflow-id>/`.
   - Confirm `active-workflows.md` shows the workflow in the Completed section.
   - Confirm `dossier.md` lifecycle state reads `done`.
   - If any check fails, report which step was incomplete and fix it before finishing.

## Output

No separate output file. The skill modifies existing state files in place and moves the packet directory.

## Completion Criteria

- `dossier.md` lifecycle state is `done`.
- Run-log has a closing entry.
- `handoff.md` reflects final state.
- Packet directory is in `.agents/workflows/done/<workflow-id>/`.
- `active-workflows.md` shows the workflow as `done`.
- `current-focus.md` is updated.

## Error Handling

- If the workflow directory does not exist at the expected path, search other lifecycle directories and report the actual location.
- If acceptance criteria are unmet, stop and report — do not mark as done.
- If `.agents/workflows/done/` does not exist, create it.
- If a workflow with the same ID already exists in `done/`, append a timestamp suffix to avoid collision.

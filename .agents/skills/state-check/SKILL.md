---
name: state-check
description: |
  Verify that all workflow and project state documents are consistent. Use when
  the user says "state check", "check state", or when session-init flags
  inconsistencies. Checks for orphan directories, dangling table entries,
  lifecycle mismatches, stale handoffs, and empty run-logs.
---

# state-check

## Purpose

This skill checks for common state inconsistencies: workflows listed in `active-workflows.md` without matching directories, directories without matching table entries, lifecycle state mismatches between dossiers and directory locations, stale handoffs, and empty run-logs. Run it after completing a workflow, at session start, or whenever state feels uncertain.

## Preconditions

- The `.agents/` directory exists with the standard structure.

## Required Reads

1. `.agents/state/active-workflows.md` [required] -- coordination index.
2. `.agents/state/current-focus.md` [required] -- project focus.
3. All `dossier.md` files in workflow lifecycle directories.
4. All `handoff.md` files in active workflow directories.
5. All `run-log.md` files in active workflow directories.

## Procedure

1. **Parse active-workflows.md.** Extract every workflow ID, its listed state, and its listed owner.
2. **Scan lifecycle directories.** For each lifecycle directory (`active/`, `blocked/`, `suspended/`, `done/`, `failed/`, `draft/`, `abandoned/`), list the workflow subdirectories present.
3. **Cross-reference table vs. directories.**
   - For every workflow in the table: verify a corresponding directory exists in the lifecycle directory matching the table's state column. Flag mismatches.
   - For every workflow directory found: verify it has a corresponding row in the table. Flag orphan directories.
4. **Check dossier lifecycle state.** For each workflow directory with a `dossier.md`, read the `Lifecycle State` metadata and verify it matches the directory location. Flag mismatches.
5. **Check current-focus.md references.** Verify that any workflow IDs mentioned in `current-focus.md` correspond to existing workflows. Flag dangling references.
6. **Check handoff freshness.** For each active workflow, check if `handoff.md` exists and has content beyond the template. Warn if a workflow has been active for more than one session but `handoff.md` is still a template placeholder.
7. **Check run-log content.** For each active workflow, check if `run-log.md` has any entries beyond the template. Warn if a workflow has been active but the run-log is empty.
8. **Report results.** Output a summary:

```
State Check Results:

Consistent: <count> workflows
Inconsistencies found:
- <workflow-id>: <description of inconsistency>
- ...

Warnings:
- <workflow-id>: handoff.md is stale / run-log.md is empty
- ...

No inconsistencies found.  (if clean)
```

## Output

Results are delivered as a direct response to the user, not written to a file.

## Completion Criteria

- All lifecycle directories have been scanned.
- All table entries have been cross-referenced against directories.
- All dossier lifecycle states have been checked.
- `current-focus.md` references have been validated.
- Handoff and run-log freshness has been checked for active workflows.
- A clear summary has been delivered.

## Error Handling

- If `active-workflows.md` does not exist, report: "No active-workflows.md found. Cannot perform state check."
- If a lifecycle directory does not exist, skip it and note: "Directory .agents/workflows/<state>/ does not exist."
- If a dossier is missing from a workflow directory, flag it: "<workflow-id>: missing dossier.md."

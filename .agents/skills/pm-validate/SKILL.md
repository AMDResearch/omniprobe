---
name: pm-validate
description: |
  Validate Project Memory for structural correctness. Use when the user says
  "validate PM", when session-init flags inconsistencies, or periodically to
  detect PM rot. Checks for broken anchors, stale units, schema violations,
  orphan files, and index drift. Auto-heals index entries.
---

# pm-validate

## Purpose

Detect PM rot before it misleads future sessions. This skill checks that PM is structurally sound -- it does not assess whether PM *coverage* is appropriate (that is `pm-reflect`).

## Preconditions

- PM has been initialized (`.agents/pm/pm-index.md` exists and lists at least one unit).
- No other agent is concurrently writing PM files. If `active-workflows.md` shows a PM-maintenance workflow in progress, stop and report the conflict.

## Required Reads

1. `.agents/pm/pm-index.md` -- the unit registry.
2. `.agents/pm/pm-current-state.md` -- project-level summary.
3. `.agents/pm/pm-decisions.md` -- decision log.
4. `.agents/pm/pm-glossary.md` -- terminology index.
5. Every file listed in `pm-index.md` under `units/`.

## Procedure

1. **Index completeness.** For each unit listed in `pm-index.md`, confirm the file exists at `.agents/pm/units/<unit>.md`. Record any missing files.
2. **Orphan detection.** List every `.md` file in `.agents/pm/units/` that is NOT referenced by `pm-index.md`. Record each orphan.
3. **Unit schema check.** Each unit file must contain the required sections for its type.
   **Infrastructure units** (type `infra` in index): Purpose, Current Truth, Boundaries and Dependencies, Anchors/References, Negative Knowledge, Open Questions, Related Workflows, Last Verified.
   **Code-navigation units** (type `code-nav` in index): Responsibility, Key Source Files, Key Types and Classes, Key Functions and Entry Points, Data Flow, Invariants, Dependencies, Negative Knowledge, Open Questions, Last Verified.
   **Architecture overview** (type `arch-overview`): validate it contains a subsystem table and loading guidance.
   Record any unit missing one or more sections.
4. **Anchor validation.** For each file path or code symbol listed under Anchors/References, verify the path exists in the repo. Record broken anchors with the unit name and the dead reference.
5. **Staleness check.** Compare each unit's `Last Verified` date to the current date. Flag any unit not verified within the last 30 calendar days.
6. **Cross-reference consistency.** Check that any workflow ID mentioned in a unit's Related Workflows section corresponds to a packet directory under `.agents/workflows/`. Flag dangling references.
7. **Current-state drift.** Confirm that every unit mentioned in `pm-current-state.md` still exists. Flag references to deleted or renamed units.
8. **Auto-heal index drift.** After identifying inconsistencies:
   a. For every `.md` file in `.agents/pm/units/` (excluding files starting with `_`) that
      is not listed in `pm-index.md`, add it to the index with status `needs-review` and
      a placeholder purpose derived from the file's first heading or Purpose section.
   b. For every entry in `pm-index.md` whose file does not exist on disk, remove the entry
      and report: "Removed dangling index entry: <unit-name>."
   c. For every indexed unit whose `Last Verified` date is older than 30 days, mark it as
      `stale` in the report.
   d. For every unit file that is still generic placeholder content (contains "None yet."
      in 5+ sections), flag it: "<unit-name> appears to be an unpopulated placeholder.
      Either populate it or delete it."

## Output

Write a validation report to `.agents/pm/validation-report.md` with the following format:

```markdown
# PM Validation Report

**Date:** YYYY-MM-DD
**Status:** PASS | ISSUES FOUND

## Missing Units
- <unit name> -- listed in index but file absent

## Orphan Units
- <file path> -- file exists but not in index

## Schema Violations
- <unit name> -- missing sections: <list>

## Broken Anchors
- <unit name> :: <dead reference>

## Stale Units
- <unit name> -- last verified: <date>

## Dangling Workflow References
- <unit name> :: <workflow-id>

## Current-State Drift
- <reference> -- missing from pm-index
```

Omit any section where no issues were found.

## Completion Criteria

- Every unit listed in `pm-index.md` has been checked against all seven validation steps.
- The validation report is written and contains either `PASS` or a concrete list of issues.
- No issue is described vaguely -- each entry names the specific unit and the specific problem.

## Error Handling

- If `pm-index.md` does not exist or is empty, stop and report: "PM not initialized. Run pm-init first."
- If a unit file cannot be read (permissions, encoding), log it as a schema violation with the note "unreadable" and continue with remaining units.
- If the repo has no git history (anchor validation requires file existence checks), skip anchor validation and note it was skipped in the report.
- Do NOT delete unit files. Auto-heal (step 8) only modifies the index.

---
name: pm-restructure
description: |
  Execute structural recommendations from pm-reflect's reflection report —
  splits, merges, removals, and coverage gap fills — with explicit user
  approval for each change. Use after reviewing a pm-reflect report and
  deciding which recommendations to act on.
---

# pm-restructure

## Purpose

Close the gap between `pm-reflect` (analysis-only) and `pm-update` (content changes to existing units). This skill handles structural operations on PM units: splitting one unit into multiple, merging multiple into one, archiving obsolete units, and creating new units for uncovered areas. Each change requires explicit user approval.

## Preconditions

- PM has been initialized (`.agents/pm/pm-index.md` exists).
- A reflection report exists at `.agents/pm/reflection-report.md`, produced by `pm-reflect`.

## Required Reads

1. `.agents/pm/reflection-report.md` [required] -- the reflection report driving this session.
2. `.agents/pm/pm-index.md` [required] -- current unit registry.
3. `.agents/pm/pm-current-state.md` -- current project state summary.
4. The unit files named in the recommendations you will act on (read on demand, not all at once).

## Procedure

1. **Check for reflection report.** If `.agents/pm/reflection-report.md` does not exist, stop
   with: "No reflection report found. Run `/pm-reflect` first to generate recommendations."

2. **Parse recommendations.** Read the reflection report and extract each recommendation as a
   discrete action item. Classify each as one of:
   - **split** -- divide a unit into two or more new units.
   - **merge** -- combine two or more units into one.
   - **archive** -- remove an obsolete unit (move to `.agents/pm/archive/`).
   - **create** -- create a new unit for an uncovered work area.

   Skip recommendations that describe content-level changes (e.g., "move this statement to a
   workflow packet", "add negative knowledge about X"). Those are `pm-update` operations —
   note them in the output as deferred to `pm-update`.

3. **Present recommendations.** Show the user a numbered summary of all structural
   recommendations with their type and affected units. Example:

   ```
   Structural recommendations from reflection report:

   1. [split] template-engine -- covers 4 unrelated topics (layout, content, skills, adapters)
   2. [merge] auth-core + auth-middleware -- both cover authentication
   3. [archive] legacy-migration -- referenced by 0 recent workflows
   4. [create] ci-pipeline -- no PM unit covers CI/CD

   Content-level items deferred to pm-update: 2 items (see reflection report)
   ```

4. **Process each recommendation.** For each structural recommendation, in order:

   a. **Present the proposed change.** Show what will happen:
      - For **split**: which unit will be split, what the new units will be named, and how
        sections will be distributed.
      - For **merge**: which units will be combined, what the merged unit will be named, and
        how conflicting content will be resolved.
      - For **archive**: which unit will be moved to `.agents/pm/archive/` and why.
      - For **create**: what the new unit will cover, its name, and which schema it will use
        (infrastructure 8-section or code-navigation 10-section).

   b. **Wait for user approval.** Use AskUserQuestion to ask the user whether to proceed.
      Options: "Approve", "Skip", "Modify" (let the user adjust the proposed change).
      If the user skips, move to the next recommendation.

   c. **Execute the approved change.** Perform the structural operation:

      **Split:**
      - Read the source unit fully.
      - Create the new unit files, distributing sections according to the approved plan.
        Every section from the original must appear in exactly one of the new units.
      - Verify no content was lost: every non-empty section in the original must have its
        content present in one of the new units.
      - Remove the original unit file.
      - Update `pm-index.md`: remove the old row, add rows for each new unit.

      **Merge:**
      - Read all source units fully.
      - Create the merged unit file. For each section, combine content from all sources.
        If two units have conflicting statements in the same section, present the conflict
        to the user and ask which to keep (or keep both with a note).
      - Verify no content was lost: every non-empty section from every source must have its
        content present in the merged unit.
      - Remove the source unit files.
      - Update `pm-index.md`: remove the old rows, add one row for the merged unit.

      **Archive:**
      - Create `.agents/pm/archive/` if it does not exist.
      - Move the unit file to `.agents/pm/archive/`.
      - Remove the unit's row from `pm-index.md`.

      **Create:**
      - Determine the appropriate schema:
        - If the unit covers a software subsystem with source files: use the code-navigation
          schema (10 sections: Responsibility, Key Source Files, Key Types and Classes,
          Key Functions and Entry Points, Data Flow, Invariants, Dependencies, Negative
          Knowledge, Open Questions, Last Verified).
        - Otherwise: use the infrastructure schema (8 sections: Purpose, Current Truth,
          Boundaries and Dependencies, Anchors/References, Negative Knowledge, Open
          Questions, Related Workflows, Last Verified).
      - Create the unit file with all required sections. Populate sections with known facts
        from the reflection report and any context available. Mark unpopulated sections as
        "None yet."
      - Add a row to `pm-index.md`.

   d. **Report the result.** After each operation, confirm what was done:
      "Done: split `template-engine` into `template-layout` and `template-content`."

5. **Update cross-references.** After all approved operations are complete:
   - Scan `pm-current-state.md` for references to renamed or removed units. Update them.
   - Scan remaining unit files' Boundaries/Dependencies sections for references to changed
     units. Update them.
   - Update `pm-index.md` metadata (purpose, facet, load guidance) for any units that
     absorbed content from other units.

6. **Set Last Verified.** For every unit file that was created or modified, set `Last Verified`
   to today's date with a note like "Created by pm-restructure" or "Merged from X + Y."

7. **Produce summary.** Output a summary of all changes made:

   ```
   PM Restructure Summary:

   Executed:
   - [split] template-engine → template-layout + template-content
   - [archive] legacy-migration → .agents/pm/archive/

   Skipped:
   - [merge] auth-core + auth-middleware (user declined)

   Deferred to pm-update:
   - 2 content-level items (transient noise cleanup)

   Cross-references updated: pm-current-state.md, auth-core.md
   ```

## Output

- Modified/created/archived files in `.agents/pm/units/` and `.agents/pm/archive/`.
- Updated `.agents/pm/pm-index.md`.
- Updated `.agents/pm/pm-current-state.md` (cross-references only).
- Summary delivered to the user in conversation.

## Completion Criteria

- Every structural recommendation from the reflection report has been presented to the user.
- Approved changes have been executed with no content loss.
- `pm-index.md` accurately reflects the current unit set on disk.
- Cross-references in `pm-current-state.md` and other unit files have been updated.
- A summary of all changes (executed, skipped, deferred) has been delivered.

## Error Handling

- If `.agents/pm/reflection-report.md` does not exist, stop: "No reflection report found. Run `/pm-reflect` first to generate recommendations."
- If the reflection report contains no structural recommendations (only content-level items), report: "No structural changes recommended. Use `/pm-update` for the content-level items in the report."
- If a split or merge would lose content (a non-empty section has no destination), stop the operation, show the orphaned content, and ask the user where it should go.
- If a unit file referenced in a recommendation does not exist on disk, skip that recommendation with a warning: "Unit `<name>` not found on disk — skipping."
- Do not modify units that are not part of an approved recommendation. Content corrections belong in `pm-update`.

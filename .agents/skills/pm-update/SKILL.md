---
name: pm-update
description: |
  Persist durable knowledge back into Project Memory after meaningful work. Use
  at session end or after completing a significant task. Updates affected PM
  units, pm-current-state.md, decisions, glossary, and code-navigation units so
  the next session inherits accurate project truth.
---

# pm-update

## Purpose

Persist durable knowledge back into Project Memory after meaningful work. Update affected PM units so the next session inherits accurate project truth. This is not a session log -- only write things that will still be true and useful tomorrow.

## Required Reads

1. `.agents/pm/pm-usage.md` -- review the update criteria before writing anything.
2. `.agents/pm/pm-index.md` -- know which units exist.
3. The PM units you loaded during this session (via pm-load).

## Procedure

1. **Filter for durability.** Review what you learned or changed during the session. Only persist knowledge that meets at least one of these criteria:
   - A durable boundary became clear (e.g., "module X cannot import from module Y").
   - A project-wide decision was made that affects future work.
   - Negative knowledge would save a future session significant time (e.g., "approach A fails because of constraint B").
   - A previously recorded fact is now wrong and must be corrected.
2. **Update affected unit files.** For each relevant `.agents/pm/units/<unit>.md`:
   - Update `Current Truth` with new verified facts.
   - Add to `Negative Knowledge` if you discovered something that does not work.
   - Update `Boundaries and Dependencies` if relationships changed.
   - Clear or update `Open Questions` that were resolved.
   - Set `Last Verified` to today's date with a one-line note.
3. **Refresh code-navigation units.** If source files were created, renamed, moved, or
   substantially restructured during this session:
   a. Identify which code-navigation units (type `code-nav` in `pm-index.md`) are affected.
   b. Update `Key Source Files` — add new files, remove deleted ones, update paths for moved files.
   c. Update `Key Types and Classes` and `Key Functions and Entry Points` if new public types
      or entry points were added.
   d. Update `Data Flow` if the flow through the subsystem changed.
   e. Add to `Negative Knowledge` if an approach was tried and abandoned.
   f. Set `Last Verified` to today's date.
   g. If a new subsystem emerged (new cluster of files with a distinct responsibility),
      create a new code-navigation unit and add it to `pm-index.md`.

   Code-navigation units are expected to need more frequent updates than infrastructure
   units. This is by design — they trade durability for actionability.
4. **Update `pm-current-state.md`.** Refresh the summary if:
   - Active work areas changed.
   - A new risk was identified or an old risk was resolved.
   - A workflow changed state (started, completed, failed, blocked).
   - The recommended read order for the next session should change.
5. **Record decisions (check every time).** Review the work done this session and ask:
   "Was any durable project decision made?" This includes:
   - Technology or language choices
   - Architecture decisions (patterns, module boundaries, data flow)
   - Scope decisions (what's in, what's deferred)
   - UX or design decisions (interaction models, visual conventions)
   - Process decisions (testing strategy, review approach, deployment model)

   If yes, add a one-line entry to `pm-decisions.md`:
   `| <YYYY-MM-DD> | <decision summary> | <1-sentence rationale> | <workflow-id or "ad-hoc"> |`

   Do not skip this step. An empty `pm-decisions.md` after multiple workflows is a
   process failure, not a sign that no decisions were made.
6. **Record terminology (check every time).** Review the work done this session and ask:
   "Was any new project-specific term, abbreviation, constant name, or calibration parameter
   introduced?" If yes, add it to `pm-glossary.md`:
   `| <term> | <meaning> | <where-used or "project-wide"> |`
7. **Update `pm-index.md`** if you created a new unit or if a unit's purpose or facet changed.
8. **Create new units if needed.** If you worked in an area that has no PM unit and the knowledge is durable, create a new `.agents/pm/units/<area>.md` with all eight standard sections and add it to the index.

## Output

- Modified files in `.agents/pm/` (units, index, current-state, decisions, glossary as applicable).
- No new files outside `.agents/pm/`.

## Completion Criteria

- Every unit you touched has an updated `Last Verified` date.
- `pm-current-state.md` reflects the project state as of this moment.
- `pm-index.md` lists every unit file that exists in `units/`.
- No session-specific or chronological content was written into PM (that belongs in run-log or session captures).

## Error Handling

- If a unit file is missing from disk but listed in the index, either recreate it from what you know or remove it from the index. Do not leave dangling references.
- If you are unsure whether knowledge is durable, err on the side of not writing it. You can always add it in the next session.
- If `pm-index.md` does not exist, run `pm-init` before attempting updates.

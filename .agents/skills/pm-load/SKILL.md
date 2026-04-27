---
name: pm-load
description: |
  Load the smallest set of Project Memory units relevant to the current task.
  Use at the start of any task that needs project context. Reads pm-index.md,
  selects 1-3 relevant units based on task scope, and loads them into working
  memory without polluting context with unrelated knowledge.
---

# pm-load

## Purpose

Load the smallest set of Project Memory units relevant to the current task. This avoids polluting context with unrelated project knowledge and keeps token budgets tight.

## Required Reads

1. `.agents/pm/pm-current-state.md` -- read first; it tells you the recommended read order, active risks, and which areas are currently in flux.
2. `.agents/pm/pm-index.md` -- the full unit listing with facets and load-when guidance.

## Procedure

1. **Identify the task scope.** From the active workflow dossier, user request, or session goal, determine which project areas the task touches. Examples: "fix a test" touches testing and the module under test; "add an API endpoint" touches architecture and data-model.
2. **Load the architecture overview first.** Check `pm-index.md` for a unit marked
   `always-load: true` (typically `architecture.md`). If one exists, read it first. This
   gives you the system-level view: subsystem map, relationships, and pointers to
   subsystem units.
3. **Select relevant subsystem units.** Based on the architecture overview and the task
   scope, identify 1-3 subsystem code-navigation units (type `code-nav` in the index)
   that cover the areas your task will touch. Read their Key Source Files, Key Functions,
   Data Flow, and Invariants sections. These tell you exactly which files to open and
   what constraints apply.
4. **Load infrastructure units only if needed.** If the task touches build/CI, testing
   infrastructure, or documentation, load the relevant infrastructure unit. Most
   implementation tasks do not need these.
5. **Read the selected units.** For each loaded unit, absorb Current Truth / Key Source
   Files, Boundaries / Dependencies, and Negative Knowledge. These are the facts that
   constrain your work.
6. **Check for stale data.** If any unit's `Last Verified` date is older than 30 days, note it as a caveat -- the information may be outdated. Do not refuse to use it, but flag it for refresh during pm-update.
7. **Read `pm-decisions.md` selectively.** Scan for decisions that affect the task's area. You do not need to read every decision.
8. **Read `pm-glossary.md` if the task involves domain-specific terms.** Skip this if the task is purely mechanical.
9. **Stop.** Do not load units outside the task scope. If you are unsure whether a unit is relevant, skip it -- you can load it later if needed.

## Output

No files are written. The output is the loaded context in your working memory. Optionally, note which units you loaded in the workflow's `run-log.md` entry for traceability.

## Completion Criteria

- You have read the architecture overview unit (if one exists).
- You have read between 1 and 3 additional units relevant to the task scope.
- You can state, in one sentence, what PM knowledge you loaded and why.

## Error Handling

- If `pm-index.md` does not exist or is empty, run the `pm-init` skill first.
- If no unit matches the task scope, load the most general unit (often `architecture.md` or `overview.md`) and note the gap -- a new unit may be needed during pm-update.
- If a unit file listed in the index is missing from disk, skip it and note the inconsistency for later repair.

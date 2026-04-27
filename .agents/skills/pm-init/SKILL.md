---
name: pm-init
description: |
  Initialize or refresh Project Memory for a repository. Use after amplifying a
  new repo, when the user says "init PM", "set up project memory", or when
  pm-index.md is missing or empty. Surveys the codebase, creates starter PM
  units, and populates the index.
---

# pm-init

## Purpose

Initialize or refresh the Project Memory scaffolding for a repository. Survey the codebase, create starter PM units for each major area, and populate the index files so future sessions can load PM selectively.

## Required Reads

1. `.agents/pm/pm-overview.md` -- understand what PM is for.
2. `.agents/pm/pm-index.md` -- check whether PM already exists (if so, this is a refresh, not a first run).
3. `.agents/pm/pm-usage.md` -- know the update criteria before writing units.

## Procedure

1. **Survey the repository.** Walk the top-level directory tree. Identify major areas: source packages, config layers, test suites, build/CI, documentation, data schemas. Note the primary language(s) and framework(s).
2. **Decide on starter units.** Create PM units at two levels:

   **a. Infrastructure units** (directory-oriented): One per major non-code area — build/CI,
   documentation, testing infrastructure, configuration. Use the path
   `.agents/pm/units/<area>.md`. Only create these for areas with enough substance to be
   useful across sessions.

   **b. Code-navigation units** (subsystem-oriented): One per major software subsystem or
   logical component — NOT per top-level directory. A subsystem is a cohesive set of source
   files that together implement a distinct responsibility (e.g., "collision detection",
   "API layer", "state management", "authentication"). Use the path
   `.agents/pm/units/<subsystem>.md`.

   To identify subsystems: read the main source directories, identify clusters of files that
   work together, and group them by responsibility. A 10-file project may have 2-3 subsystems;
   a 50-file project may have 5-8. Do not create a unit per file or per class — the right
   granularity is "a cohesive area that an agent might need to understand as a whole before
   modifying any file in it."

   Before writing units, read the example unit at `.agents/pm/units/_example-subsystem.md`
   to see the expected level of detail for code-navigation units.
3. **Write each unit file.**

   **For infrastructure units**, use the existing 8-section schema:
   - Purpose, Current Truth, Boundaries and Dependencies, Anchors/References,
     Negative Knowledge, Open Questions, Related Workflows, Last Verified.

   **For code-navigation units**, use the code-navigation schema (all sections required,
   leave empty with "None yet." if nothing applies):

   - **Responsibility** — 1-2 sentences on what this subsystem does.
   - **Key Source Files** — list every file in this subsystem with its path and a one-line
     description of what it contains. Example:
     `- src/engine/CollisionDetector.swift — predicts and resolves ball-ball and ball-cushion collisions`
   - **Key Types and Classes** — list the main types/classes with brief descriptions.
     Example: `- CollisionDetector: stateless service that takes BallState[] and returns CollisionEvent[]`
   - **Key Functions and Entry Points** — list the functions an agent would need to find to
     start working in this subsystem. Include file references. Example:
     `- detectNextCollision(balls:table:) in CollisionDetector.swift — main entry point`
   - **Data Flow** — numbered steps showing how data moves through this subsystem.
     Example: `1. SimulationEngine calls detectNextCollision() → 2. Iterates ball pairs → 3. ...`
   - **Invariants** — rules that must not be broken when modifying this subsystem.
   - **Dependencies** — what other subsystems this one talks to, with "Also Load" guidance.
     Example: `Depends on PhysicsParams (load: physics-params.md). Called by SimulationEngine (load: engine.md).`
   - **Negative Knowledge** — approaches that were tried and failed, with reasoning.
   - **Open Questions** — unresolved items.
   - **Last Verified** — date and brief note.
4. **Create always-loaded architecture overview.** For code-facet projects, create a special
   unit `.agents/pm/units/architecture.md` that provides the system-level view:
   - System purpose (1-2 sentences).
   - ASCII or text diagram of major subsystems and their relationships.
   - Subsystem table: subsystem name, unit file, source location, brief responsibility.
   - External dependencies and integration points.
   - Build and run instructions (or pointer to build docs).
   - "Always load this unit first. Then load only the subsystem units relevant to your task."

   Mark this unit as `always-load: true` in `pm-index.md`.
5. **Populate `pm-index.md`.** For each unit, add a row: unit name, file path, one-line
   purpose, unit type (`code-nav` | `infra` | `arch-overview`), facet
   (arch / ops / data / test / other), `always-load` flag (true only for architecture
   overview), and guidance on when to load it.
6. **Populate `pm-current-state.md`.** Write a short summary covering: active work areas, current risks, active workflows (if any), changed assumptions, and recommended read order for the next session.
7. **Seed `pm-decisions.md`** with any project-level decisions discovered during the survey (e.g., chosen framework, deployment target). Use the format: date, decision, rationale, impact.
8. **Seed `pm-glossary.md`** with project-specific terms found during the survey.

## Output

- `.agents/pm/units/<area>.md` -- one file per identified area.
- `.agents/pm/pm-index.md` -- updated unit listing.
- `.agents/pm/pm-current-state.md` -- updated state summary.
- `.agents/pm/pm-decisions.md` -- seeded if decisions were found.
- `.agents/pm/pm-glossary.md` -- seeded if terms were found.

## Completion Criteria

- Every infrastructure unit file has all eight required sections.
- Every code-navigation unit file has all ten required sections (per the code-navigation schema).
- An architecture overview unit exists for code-facet projects and is marked `always-load: true` in the index.
- `pm-index.md` lists every unit file that exists in `units/`.
- `pm-current-state.md` contains at least a recommended read order.
- No unit is empty boilerplate -- each has at least two sections with real content.

## Error Handling

- If the repo is empty or trivial (fewer than 3 meaningful source files), create a single `overview.md` unit and note in `pm-current-state.md` that PM will grow as the project does.
- If PM already exists, do not overwrite units with less information. Merge new findings into existing sections and update `Last Verified`.
- If you cannot determine the project structure (e.g., binary-only repo), record that fact in `pm-current-state.md` and create no units.

---
name: pm-feature
description: |
  Create or manage a feature workflow packet. Use when the user wants to add new
  user-visible functionality and needs a tracked workflow with acceptance
  criteria, scope boundaries, and a verification strategy.
---

# pm-feature

## Purpose

Create or manage a feature workflow packet. Features add new user-visible behavior. This skill emphasizes clear acceptance criteria, user-facing behavior definitions, and release risk awareness.

## Required Reads

1. `.agents/workflows/INDEX.md` -- understand lifecycle states and packet structure.
2. `.agents/workflows/dossier-template.md` -- the dossier format to follow.
3. `.agents/pm/pm-current-state.md` -- check for active workflows and current project state.
4. The PM units for areas the feature will touch (via pm-load).

## Procedure

### Creating a new feature packet

1. **Choose the workflow ID.** Use the prefix `ft_` followed by a short descriptive slug. Example: `ft_user_export_csv`.
2. **Create the packet directory.** Path: `.agents/workflows/draft/ft_<slug>/`.
3. **Write `dossier.md`.** Copy the structure from `dossier-template.md` and fill in:
   - Metadata: set Workflow Type to "feature", Lifecycle State to "draft".
   - Objective: describe the user-visible behavior being added. Write from the user's perspective: "Users will be able to ..."
   - Background/Context: explain why this feature is needed and any prior discussion.
   - Contract: define what "done" looks like in observable terms.
   - Acceptance Criteria: list specific, testable conditions. Each criterion should be verifiable by running a test or manually exercising the feature. Include both happy-path and error-path criteria.
   - Failure Policy: define conditions that mean the feature cannot ship. Default: "If the feature cannot meet acceptance criteria without breaking existing tests, stop and report."
   - Scope: list the files, modules, and UI surfaces that will be created or modified.
   - Non-Goals: state adjacent features or enhancements that are explicitly excluded.
   - Dependencies: list external services, libraries, or other workflows this feature depends on.
   - Plan of Record: break the work into ordered steps. Each step should be small enough to verify independently.
   - Verification Strategy: specify how each acceptance criterion will be tested (unit test, integration test, manual check). Include the commands to run.
4. **Write `run-log.md`.** Initialize from `run-log-template.md`.
5. **Write `handoff.md`.** Initialize from `handoff-template.md`. Set "Next Exact Step" to the first planned action.
6. **Write `artifacts.md`.** Initialize from `artifacts-template.md`.
7. **Update `.agents/workflows/INDEX.md`** if a tracking table is maintained.

### Managing an existing feature packet

1. **After each step**, append a run-log entry covering: action taken, files touched, test results, and which acceptance criteria are now met.
2. **Update `handoff.md`** after every step with current status and next action.
3. **Track acceptance criteria progress** in the dossier or run-log -- mark each criterion as met or unmet.
4. **Move the packet between lifecycle directories** when state changes. Draft to active requires user approval. Active to done requires all acceptance criteria met.

## Output

- `.agents/workflows/draft/ft_<slug>/dossier.md`
- `.agents/workflows/draft/ft_<slug>/run-log.md`
- `.agents/workflows/draft/ft_<slug>/handoff.md`
- `.agents/workflows/draft/ft_<slug>/artifacts.md`

## Completion Criteria

- All four packet files exist and follow their respective templates.
- Acceptance criteria are specific and testable (no vague language like "works well").
- The plan of record has at least two discrete steps.
- The verification strategy names specific test commands or manual steps for each criterion.
- Non-goals are stated to prevent scope creep.

## Error Handling

- If acceptance criteria are unclear or missing from the user's request, draft best-guess criteria and flag them for user review before moving to active.
- If the feature scope overlaps with an active workflow, note the conflict in Dependencies and flag it to the user.
- If a dependency (external service, library) is unavailable, set the packet state to blocked, document the blocker in `handoff.md`, and stop.

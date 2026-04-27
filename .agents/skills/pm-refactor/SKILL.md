---
name: pm-refactor
description: |
  Create or manage a refactor workflow packet. Use when the user wants to
  restructure existing code without changing user-visible behavior. Emphasizes
  boundary preservation, regression risk identification, and verification gates
  at each step.
---

# pm-refactor

## Purpose

Create or manage a refactor workflow packet. Refactors restructure existing code without changing user-visible behavior. This skill emphasizes boundary preservation, regression risk identification, and verification gates at each step.

## Required Reads

1. `.agents/workflows/INDEX.md` -- understand lifecycle states and packet structure.
2. `.agents/workflows/dossier-template.md` -- the dossier format to follow.
3. `.agents/pm/pm-current-state.md` -- check for active workflows that might conflict.
4. The PM units for the area being refactored (via pm-load).

## Procedure

### Creating a new refactor packet

1. **Choose the workflow ID.** Use the prefix `rf_` followed by a short descriptive slug. Example: `rf_extract_auth_service`.
2. **Create the packet directory.** Path: `.agents/workflows/draft/rf_<slug>/`.
3. **Write `dossier.md`.** Copy the structure from `dossier-template.md` and fill in:
   - Metadata: set Workflow Type to "refactor", Lifecycle State to "draft".
   - Objective: state what structural change is being made and why.
   - Contract: define the invariant -- what observable behavior must remain unchanged.
   - Acceptance Criteria: list specific verifiable conditions (tests pass, API contracts unchanged, no new dependencies introduced).
   - Failure Policy: define when to stop and roll back. Default: "If any existing test fails after a refactor step, revert that step and reassess."
   - Scope: list the files and modules that will be modified.
   - Non-Goals: explicitly state what behavior changes are out of scope.
   - Verification Strategy: require a test run after each discrete step, not just at the end. List the specific test commands.
   - Constraints: note any modules or interfaces that must not change shape.
4. **Write `run-log.md`.** Initialize with the header from `run-log-template.md`. Leave the body empty.
5. **Write `handoff.md`.** Initialize with the header from `handoff-template.md`. Set "Next Exact Step" to the first planned refactor action.
6. **Write `artifacts.md`.** Initialize with the header from `artifacts-template.md`.
7. **Update `.agents/workflows/INDEX.md`** if a tracking table is maintained.

### Managing an existing refactor packet

1. **Before each step**, verify that the previous step's tests still pass.
2. **After each step**, append a run-log entry with: action taken, files touched, test results, and criteria impact.
3. **Update `handoff.md`** after every step with the next exact action.
4. **Move the packet between lifecycle directories** when state changes (draft to active requires user approval, active to done when acceptance criteria are met). Update the dossier metadata and `active-workflows.md` after every move.

## Output

- `.agents/workflows/draft/rf_<slug>/dossier.md`
- `.agents/workflows/draft/rf_<slug>/run-log.md`
- `.agents/workflows/draft/rf_<slug>/handoff.md`
- `.agents/workflows/draft/rf_<slug>/artifacts.md`

## Completion Criteria

- All four packet files exist and follow their respective templates.
- The dossier has a concrete verification strategy with specific test commands.
- The failure policy explicitly addresses regression (test failure = revert).
- Scope lists every file or module that will be touched.
- The contract section clearly states what must not change.

## Error Handling

- If existing tests are already failing before the refactor begins, record this in the dossier under Constraints and do not accept blame for pre-existing failures. List the failing tests explicitly.
- If the refactor scope overlaps with an active workflow, note the conflict in the dossier's Dependencies section and flag it to the user before moving to active.
- If you cannot define a clear behavioral contract (i.e., there is no way to verify behavior is preserved), flag this as a risk and recommend writing characterization tests first.

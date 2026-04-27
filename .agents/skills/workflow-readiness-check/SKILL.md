---
name: workflow-readiness-check
description: |
  Gate check before promoting a draft workflow to active. Use after
  workflow-create to verify the packet is complete enough for autonomous
  execution. Validates dossier sections, checks for write-scope conflicts,
  and produces a pass/fail readiness checklist.
---

# workflow-readiness-check

## Purpose

Gate check before a draft workflow packet is promoted to `active`. Verify that the packet is complete enough for an agent to execute autonomously without needing to ask clarifying questions. This is the final quality gate -- nothing leaves `draft` without passing.

## Preconditions

- A workflow packet exists in `.agents/workflows/draft/<workflow-id>/` with all four files.

## Required Reads

1. `.agents/workflows/draft/<workflow-id>/dossier.md` -- the primary subject of the check.
2. `.agents/workflows/draft/<workflow-id>/handoff.md` -- verify it has a concrete next step.
3. `.agents/workflows/draft/<workflow-id>/run-log.md` -- confirm it exists and has an initial entry.
4. `.agents/workflows/draft/<workflow-id>/artifacts.md` -- confirm it exists.
5. `.agents/policy/contract.md` -- understand what contract preservation requires.
6. `.agents/state/active-workflows.md` -- check for write-scope conflicts before approving.

## Procedure

1. **Check structural completeness.** Verify all four files exist in the packet directory.
2. **Validate the dossier against each required section.** For each, determine pass/fail:
   - **Objective**: Is it specific and unambiguous? Could two different agents interpret it the same way?
   - **Acceptance Criteria**: Is each criterion observable and testable? Would an agent know exactly how to verify it passed? Reject vague criteria like "code is clean" or "performance is good."
   - **Failure Policy**: Does it state what the agent should do when the contract cannot be met? A missing failure policy is a fail.
   - **Scope**: Are the files, modules, or areas of work named? An unbounded scope is a fail.
   - **Non-Goals**: Are they explicit? At least one non-goal should exist to anchor scope.
   - **Plan of Record**: Are the first concrete steps defined? The agent must be able to start working without inventing the plan.
   - **Verification Strategy**: Does it explain how acceptance criteria will be checked?
3. **Check for dependency and conflict risks.**
   - Are dependencies on other workflows or external factors listed?
   - Does the intended write scope conflict with any active workflow in `active-workflows.md`?
4. **Check the handoff file.** Does "Next Exact Step" contain an actionable instruction, not a vague pointer?
5. **Check for specification ambiguity (design/UI/spec workflows).** If the workflow type
   involves design, UX, visual, or specification work (identified by: ft_ prefix with UI
   in the objective, design-heavy dossiers, or subjective acceptance criteria), apply these
   additional checks:

   a. **Unresolved choices.** Does the dossier contain phrases like "TBD", "to be decided",
      "we could do X or Y", or acceptance criteria that depend on subjective judgment
      ("looks good", "feels right", "appropriate")? If yes, flag: "Unresolved design choice:
      <quote>. Resolve before promotion or convert to an explicit Open Question with a
      decision owner."
   b. **Missing examples.** For any acceptance criterion that describes a visual or
      behavioral outcome, does the dossier include a concrete example, mockup description,
      or reference to an existing pattern? If not, flag: "AC-<N> describes a subjective
      outcome without a concrete example. Add an example or reference."
   c. **Expected refinement axes.** Does the dossier acknowledge which aspects are likely
      to need iteration during execution (e.g., "exact layout may change based on user
      feedback")? If the workflow is design-heavy and no refinement axes are named, flag:
      "This design workflow does not name expected refinement areas. Consider adding a
      'Known Iteration Areas' section to set expectations."

   These checks do not block promotion — they are warnings that the user should review
   before approving. Include them in the readiness report as "Ambiguity warnings" separate
   from structural pass/fail items.
6. **Compile results.** Produce a pass/fail checklist with one line per item. For each failure, state what is missing or inadequate and what the fix should be. If ambiguity warnings were generated (step 5), include them in a separate section below the structural checklist.

## Output

- **Location**: Present the checklist directly to the user in the conversation.
- **Format**: A markdown checklist. Example:
  ```
  ## Readiness Check: rf_extract-auth-module

  - [x] Objective -- specific and unambiguous
  - [x] Acceptance Criteria -- 3 criteria, all testable
  - [ ] Failure Policy -- MISSING: no failure policy defined
  - [x] Scope -- bounded to src/auth/
  - [x] Non-Goals -- 2 non-goals listed
  - [x] Plan of Record -- 5 steps, first step is concrete
  - [x] Verification Strategy -- maps to acceptance criteria
  - [x] Write-scope conflicts -- none found
  - [x] Handoff next step -- actionable

  **Result: NOT READY** -- fix Failure Policy before promoting to active.
  ```

## Completion Criteria

- Every checklist item has been evaluated with a clear pass or fail.
- If all items pass, the result is `READY` and the user is told the packet can be promoted to `active`.
- If any item fails, the result is `NOT READY` with specific remediation instructions for each failure.
- The agent does not promote the packet itself. The user must approve the `draft` to `active` transition.

## Error Handling

- If the packet directory or any of the four files is missing, report which files are absent and stop. Do not attempt a partial check.
- If the dossier uses placeholder text (e.g., `TBD`, `TODO`, `<fill in>`), treat each placeholder as a failure.
- Do not weaken the check to force a pass. If the packet is not ready, say so.

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

- A workflow packet exists in `.agents/workflows/draft/<workflow-id>/` with all five files.

## Required Reads

1. `.agents/workflows/draft/<workflow-id>/dossier.md` -- the primary subject of the check.
2. `.agents/workflows/draft/<workflow-id>/acceptance.sh` -- the executable form of the criteria.
3. `.agents/workflows/draft/<workflow-id>/handoff.md` -- verify it has a concrete next step.
4. `.agents/workflows/draft/<workflow-id>/run-log.md` -- confirm it exists and has an initial entry.
5. `.agents/workflows/draft/<workflow-id>/artifacts.md` -- confirm it exists.
6. `.agents/policy/contract.md` -- understand what contract preservation requires.
7. `.agents/state/active-workflows.md` -- check for write-scope conflicts before approving.

## Procedure

1. **Check structural completeness.** Verify all five files exist in the packet directory, and that `acceptance.sh` is executable.
2. **Validate the dossier against each required section.** For each, determine pass/fail:
   - **Objective**: Is it specific and unambiguous? Could two different agents interpret it the same way?
   - **Acceptance Criteria**: Is each criterion observable and testable? Would an agent know exactly how to verify it passed? Reject vague criteria like "code is clean" or "performance is good."
   - **Failure Policy**: Does it state what the agent should do when the contract cannot be met? A missing failure policy is a fail.
   - **Scope**: Are the files, modules, or areas of work named? An unbounded scope is a fail.
   - **Non-Goals**: Are they explicit? At least one non-goal should exist to anchor scope.
   - **Plan of Record**: Are the first concrete steps defined? The agent must be able to start working without inventing the plan.
   - **Verification Strategy**: Does it explain how acceptance criteria will be checked?
3. **Reject prose-only acceptance criteria.** This is the check that makes the rest of the gate mean anything, and each of the three conditions below is an independent failure:

   a. **`acceptance.sh` is missing.** Fail. A packet whose criteria exist only as prose will be graded at completion time by the same agent that did the work.
   b. **`acceptance.sh` contains no `ac_pass` or `ac_fail` call.** Fail. A script made entirely of `ac_weak` and `ac_judge` can never fail, so it is not a gate -- it is a report. At least one criterion must be decided outright.
   c. **An AC ID in the dossier has neither a corresponding check in `acceptance.sh` nor a `[judgement]` marker.** Fail, naming each unmatched ID. Match on the AC identifier: every `AC-<N>` heading in the dossier's Acceptance Criteria section should appear as the first argument of a verdict call, unless the dossier marks it `[judgement]` -- in which case `ac_judge` should carry it.

   Also verify, as part of the same item:
   - Every `[judgement]` marker in the dossier is accompanied by a **stated reason**. A bare marker is a failure; the reason is what the human reviewer acts on.
   - The dossier declares its write scope as a ```` ```write-scope ```` fenced block. A prose-only scope is not a structural failure for a pre-existing dossier, but for a newly created packet it is -- record it as a failure and point at the block.
   - `acceptance.sh` runs to completion. Run it. It is expected to fail at this stage, since no work has been done; what matters is that it fails by reporting unmet criteria rather than crashing, and that `ac_finish` is the last call.
   - **For every check that searches a file for text, ask: could the pattern match text that exists *because of* the thing being tested for?** The obvious case is the checking script's own source -- a `grep` for a marker string finds that string in the `grep` line itself if the script ever searches its own file, its own directory, or the repository root. But the collision is just as often in the file **being checked**: a comment explaining why the wrong form is wrong, a dated amendment note recording the change, documentation of the very rule under test, a criterion quoted back in a dossier.

     **The better a change is documented, the likelier the collision** -- which is worth naming, because the tempting response is to document less. It is the wrong response. Fix the check.

     Ask it in **both** directions, because they fail differently:

     - **False FAIL** -- the pattern matches the explanation, so a correct change reports as a defect. Loud, and self-correcting because someone must investigate.
     - **Vacuous PASS** -- the pattern is satisfied by text that was already there before any work was done, so the check would have passed against an untouched repository. Silent, and the dangerous one. A check that cannot fail is not a check.

     Four instances on record in this framework: a check looking for the word `STUB` matched its own source (2026-08-09); and three in one packet on 2026-08-17, one of each direction plus a check that grepped for `= "0.5"` while verifying the amendment that replaced it -- it could only have passed had the amendment been left undocumented.

     **What to do instead**, in order of preference:

     a. **Prefer a behavioural check.** Drive the thing and observe what it does, rather than reading its source. Both 2026-08-17 false FAILs were repaired this way and ended up establishing more than the greps had claimed.
     b. **When you must grep, anchor to a literal the code emits** -- the exact message a check prints -- not to prose describing the behaviour. That ties the document to the behaviour and cannot be satisfied by text predating the change. Where a criterion depends on this, fix the emitted string *in the criterion* so the two cannot drift.
     c. **Be suspicious of negative greps.** Asserting a string is absent breaks the moment anyone explains why it should be absent. Assert the presence of the right thing instead.
     d. Where a check must search broadly, exclude the packet directory or construct the pattern so the literal does not appear in the source.

     The question is worth asking explicitly because the code reads correctly. Nothing is wrong with the line in isolation; the defect is in the relationship between the pattern and the set of files searched, which only becomes visible when you ask this or when you run it -- and a correctly-worded warning has now failed to prevent it four times, so treat running the check against input that should fail it as the real safeguard.

4. **Check for dependency and conflict risks.**
   - Are dependencies on other workflows or external factors listed?
   - Does the intended write scope conflict with any active workflow in `active-workflows.md`?
   - Does the dossier write into **another workflow's packet directory** — a completed packet's
     `dossier.md`, another packet's `acceptance.sh`? Those paths must appear in the `write-scope`
     block. A packet's own directory is exempt; another's is not, and an undeclared write there
     is reported by the gate.
5. **Report the base-commit stamp.** Read the dossier's `- Base Commit:` metadata line and emit
   one checklist line for it. Do not write the value — that belongs to whoever performs the
   `draft` → `active` move, and this skill does not promote.
   - Placeholder (`(unstamped — set at promotion)`) on a `draft` packet: **pass**, noting the
     stamp is due at promotion.
   - Line absent entirely: **warn**, and say the promoting agent must add it.
   - A resolved sha already present on a `draft` packet: **pass**, noting it will be stale if
     promotion does not follow shortly, since the range is measured from it.
   - In a sidecar install, apply the same to `- Base Commit (code):`.

   The stamp is what lets `ac_check_write_scope` see writes that have already been committed;
   without it an `active` packet's scope check reports `WEAK` rather than `PASS`. See
   `.agents/workflows/INDEX.md`.
6. **Check the handoff file.** Does "Next Exact Step" contain an actionable instruction, not a vague pointer?
7. **Check for specification ambiguity (design/UI/spec workflows).** If the workflow type
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

   Note the distinction from step 3: an unresolved *design* choice is a warning, while an
   acceptance criterion that nothing can decide is a structural failure. The first is a risk the
   user may accept; the second means the packet has no gate.
8. **Compile results.** Produce a pass/fail checklist with one line per item. For each failure, state what is missing or inadequate and what the fix should be. If ambiguity warnings were generated (step 7), include them in a separate section below the structural checklist.

## Output

- **Location**: Present the checklist directly to the user in the conversation.
- **Format**: A markdown checklist. Example:
  ```
  ## Readiness Check: rf_extract-auth-module

  - [x] Objective -- specific and unambiguous
  - [x] Acceptance Criteria -- 3 criteria, all testable
  - [ ] Failure Policy -- MISSING: no failure policy defined
  - [x] Scope -- bounded to src/auth/, declared as a write-scope block
  - [x] Non-Goals -- 2 non-goals listed
  - [x] Plan of Record -- 5 steps, first step is concrete
  - [x] Verification Strategy -- maps to acceptance criteria
  - [x] acceptance.sh -- present, executable, runs to completion
  - [ ] Criteria coverage -- AC-3 has no check and no [judgement] marker
  - [x] Judgement markers -- 1 marked, reason stated
  - [x] Base Commit -- placeholder present; stamp at promotion with `git rev-parse HEAD`
  - [x] Write-scope conflicts -- none found
  - [x] Handoff next step -- actionable

  **Result: NOT READY** -- fix Failure Policy and give AC-3 a check or a marked reason
  before promoting to active.
  ```

## Completion Criteria

- Every checklist item has been evaluated with a clear pass or fail.
- If all items pass, the result is `READY` and the user is told the packet can be promoted to `active`.
- If any item fails, the result is `NOT READY` with specific remediation instructions for each failure.
- The agent does not promote the packet itself. The user must approve the `draft` to `active` transition.

## Error Handling

- If the packet directory or any of the five files is missing, report which files are absent and stop. Do not attempt a partial check.
- If the dossier uses placeholder text (e.g., `TBD`, `TODO`, `<fill in>`), treat each placeholder as a failure. The same applies to `acceptance.sh`: an unedited copy of the template still carries its `TODO` line.
- Do not weaken the check to force a pass. If the packet is not ready, say so.
- Do not resolve a coverage failure by adding a `[judgement]` marker to the dossier yourself. The marker is a claim about the criterion, and it belongs to whoever wrote it -- report the gap and let it be fixed upstream.

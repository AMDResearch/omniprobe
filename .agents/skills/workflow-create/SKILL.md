---
name: workflow-create
description: |
  Create a complete workflow packet from a clear work request or refined brief.
  Use when the user has a well-defined task ready to become a tracked workflow,
  or after workflow-refine produces a brief. Creates dossier, run-log, handoff,
  and artifacts files in draft state.
---

# workflow-create

## Purpose

Create a complete workflow packet from a clear work request or a refined brief produced by `workflow-refine`. The packet is placed in `draft` state and contains all four required files, ready for a readiness check.

## Preconditions

- A clear work request exists: either a refined brief from `workflow-refine`, or direct user input that already contains an unambiguous objective, acceptance criteria, and scope.
- If the input is still vague, run `workflow-refine` first. Do not create a packet from ambiguous input.

## Required Reads

1. `.agents/workflows/dossier-template.md`
2. `.agents/workflows/run-log-template.md`
3. `.agents/workflows/handoff-template.md`
4. `.agents/workflows/artifacts-template.md`
5. `.agents/workflows/INDEX.md` -- understand lifecycle rules and naming.
6. `.agents/state/active-workflows.md` -- check for write-scope conflicts.
7. `.agents/policy/contract.md` -- understand contract preservation rules.

## Procedure

1. **Pick the workflow type.** Use the appropriate prefix based on the work:
   - `rf_` -- refactor
   - `ft_` -- feature
   - `iv_` -- investigation
   - `rv_` -- review
   - `pf_` -- performance
2. **Choose a workflow ID.** Format: `<prefix><short-descriptive-slug>`, e.g., `ft_user-export`, `rf_extract-auth-module`. Use lowercase and hyphens.
3. **Create the packet directory** at `.agents/workflows/draft/<workflow-id>/`.
4. **Write `dossier.md`** using the dossier template. Fill in every section:
   - Metadata: workflow ID, type, lifecycle state (`draft`), owner, intended write scope, dependencies on other active workflows.
   - Objective: one or two sentences.
   - Acceptance Criteria: observable, testable conditions. Each criterion must be verifiable without subjective judgment.
   - Failure Policy: what the agent should do if the contract cannot be met (stop and report, or attempt a fallback).
   - Scope: files, modules, or areas the work will touch.
   - Non-Goals: explicitly state what is out of scope.
   - Plan of Record: numbered steps the agent will follow.
   - Verification Strategy: how each acceptance criterion will be checked.
   - Leave Open Questions empty or populated only with genuine unknowns.
5. **Write `run-log.md`** using the run-log template. Add an initial entry recording the packet creation.
6. **Write `handoff.md`** using the handoff template. Set:
   - Current Status: `Packet created, awaiting readiness check.`
   - Next Exact Step: `Run workflow-readiness-check on this packet.`
   - Required Reads Before Resuming: list the dossier.
7. **Write `artifacts.md`** using the artifacts template. Leave it as a header-only skeleton.
8. **Update `.agents/state/active-workflows.md`** to list the new workflow with state `draft`.
9. **If a seed file was the source**, note this in the dossier References section.

## Output

- **Location**: `.agents/workflows/draft/<workflow-id>/` containing `dossier.md`, `run-log.md`, `handoff.md`, `artifacts.md`.
- **Format**: Markdown files following their respective templates.

## Completion Criteria

- The packet directory exists under `draft/` with all four files.
- Every contract-controlled section in the dossier (Objective, Acceptance Criteria, Failure Policy, Scope, Non-Goals) is populated with specific content, not placeholder text.
- `active-workflows.md` reflects the new draft workflow.
- The handoff file points to `workflow-readiness-check` as the next step.

## Error Handling

- If the work request lacks an objective or acceptance criteria, stop and invoke `workflow-refine` instead. Do not create a packet with placeholder acceptance criteria.
- If the intended write scope overlaps with another active workflow, flag the conflict in the dossier's Dependencies section and in `active-workflows.md`. Ask the user whether to proceed.
- If you cannot determine the correct workflow type, ask the user. Do not default to `ft_` as a guess.

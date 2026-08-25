---
name: workflow-create
description: |
  Create a complete workflow packet from a clear work request or refined brief.
  Use when the user has a well-defined task ready to become a tracked workflow,
  or after workflow-refine produces a brief. Creates dossier, run-log, handoff,
  artifacts, and acceptance.sh files in draft state.
---

# workflow-create

## Purpose

Create a complete workflow packet from a clear work request or a refined brief produced by `workflow-refine`. The packet is placed in `draft` state and contains all five required files, ready for a readiness check.

The fifth file, `acceptance.sh`, is the point of the exercise: acceptance criteria written only as prose are graded by the same agent that did the work. Writing them as a script forces each criterion to name the fact that settles it, and makes exit 0 the only evidence a workflow may stop.

## Preconditions

- A clear work request exists: either a refined brief from `workflow-refine`, or direct user input that already contains an unambiguous objective, acceptance criteria, and scope.
- If the input is still vague, run `workflow-refine` first. Do not create a packet from ambiguous input.

## Required Reads

1. `.agents/workflows/dossier-template.md`
2. `.agents/workflows/run-log-template.md`
3. `.agents/workflows/handoff-template.md`
4. `.agents/workflows/artifacts-template.md`
5. `.agents/workflows/acceptance-template.sh` -- the starting point for the fifth packet file.
6. `.agents/workflows/INDEX.md` -- understand lifecycle rules and naming, and the four verdict classes.
7. `.agents/state/active-workflows.md` -- check for write-scope conflicts.
8. `.agents/policy/contract.md` -- understand contract preservation rules.

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
   - Metadata: workflow ID, type, lifecycle state (`draft`), owner, dependencies on other active workflows, and the write scope as a fenced ```` ```write-scope ```` block -- one path per line, directories ending in a slash. The block is what `ac_check_write_scope` parses, so a scope declared only in prose will drift from the scope that is checked.
   - Metadata, `Base Commit`: write the literal placeholder `- Base Commit: (unstamped — set at promotion)`. The real value is stamped at the `draft` → `active` transition with `git rev-parse HEAD`; a packet in `draft` has not started, so there is nothing yet to be the base of. Write the line anyway -- an absent line reads as an omission, while the placeholder says the convention was followed and the value is not due yet. See `.agents/workflows/INDEX.md` for what the stamp does and for the sidecar's second `- Base Commit (code):` line.
   - Metadata, write scope, on *other* packets: a workflow may write anywhere inside its own packet directory without declaring it, but writing into another workflow's packet -- amending a completed dossier, editing another packet's `acceptance.sh` -- must be declared here like any other path.
   - Objective: one or two sentences.
   - Acceptance Criteria: numbered `AC-1`, `AC-2`, ... Each must be observable and testable. Classify each one as you write it (see step 5) and reword any that resist classification -- it is cheaper to fix a criterion now than to discover at completion time that nothing can decide it.
   - Failure Policy: what the agent should do if the contract cannot be met (stop and report, or attempt a fallback).
   - Scope: files, modules, or areas the work will touch.
   - Non-Goals: explicitly state what is out of scope.
   - Plan of Record: numbered steps the agent will follow.
   - Verification Strategy: how each acceptance criterion will be checked.
   - Leave Open Questions empty or populated only with genuine unknowns.
5. **Classify every acceptance criterion.** Each falls into exactly one of three classes, and the class determines both how the dossier states it and which verdict function checks it:

   | Class | Dossier | `acceptance.sh` | Gates |
   |-------|---------|-----------------|-------|
   | Executable | plain criterion | `ac_pass` / `ac_fail` | yes |
   | Weak | criterion plus a note that the check is indirect | `ac_weak` on success, `ac_fail` on failure | no |
   | Judgement | criterion marked `[judgement]` **with a stated reason** | `ac_judge`, reason as the third argument | no |

   A **weak** check establishes something adjacent to the criterion rather than the criterion itself -- almost always text presence. A grep for "target repo" also matches a document saying "do NOT treat the target repo as the codebase", so it proves the words are there and nothing more. Report it as `ac_weak`. Do not promote it to `ac_pass` because the output looks better that way.

   A **judgement** criterion cannot be decided by any script -- typically a claim about how an agent behaves after reading a document. It requires the `[judgement]` marker in the dossier **and a stated reason for why it is not checkable**. A bare marker is not acceptable: the reason is what a human reviewer acts on, and what the optional validator receives. Reuse the same reason as the third argument to `ac_judge`.

   Before accepting either weaker class, try rewording the criterion so a command can decide it. Often a criterion about behaviour can be split into a mechanical half that is asserted and a judgement half that is marked -- state both. Expect roughly a fifth of a real dossier to resist; that ratio is a property of this kind of work, not a defect.

6. **Write `acceptance.sh`** by copying `.agents/workflows/acceptance-template.sh` into the packet directory and replacing every `TODO`. One call per criterion, in the dossier's order, using the verdict its class dictates. Set `AC_WORKFLOW_ID` and `AC_DOSSIER_PATH`, keep the `ac_check_write_scope` call, and end with `ac_finish`. Set the executable bit.

   Run it before moving on. It will fail -- no work has been done yet -- but it must fail by reporting unmet criteria, not by crashing. A script that errors out is not a gate.

7. **Write `run-log.md`** using the run-log template. Add an initial entry recording the packet creation.
8. **Write `handoff.md`** using the handoff template. Set:
   - Current Status: `Packet created, awaiting readiness check.`
   - Next Exact Step: `Run workflow-readiness-check on this packet.`
   - Required Reads Before Resuming: list the dossier.
9. **Write `artifacts.md`** using the artifacts template. Leave it as a header-only skeleton.
10. **Update `.agents/state/active-workflows.md`** to list the new workflow with state `draft`.
11. **If a seed file was the source**, note this in the dossier References section.

## Output

- **Location**: `.agents/workflows/draft/<workflow-id>/` containing `dossier.md`, `run-log.md`, `handoff.md`, `artifacts.md`, and `acceptance.sh`.
- **Format**: Markdown files following their respective templates, plus one executable bash script.

## Completion Criteria

- The packet directory exists under `draft/` with all five files, and `acceptance.sh` is executable.
- Every contract-controlled section in the dossier (Objective, Acceptance Criteria, Failure Policy, Scope, Non-Goals) is populated with specific content, not placeholder text.
- The dossier declares its write scope as a ```` ```write-scope ```` block.
- Every acceptance criterion has either a check in `acceptance.sh` or a `[judgement]` marker with a stated reason. No criterion has neither.
- `acceptance.sh` runs to completion and reports unmet criteria rather than crashing.
- `active-workflows.md` reflects the new draft workflow.
- The handoff file points to `workflow-readiness-check` as the next step.

## Error Handling

- If the work request lacks an objective or acceptance criteria, stop and invoke `workflow-refine` instead. Do not create a packet with placeholder acceptance criteria.
- If a criterion cannot be checked and you cannot articulate *why* it cannot be checked, it is not ready to be a criterion. Do not mark it `[judgement]` to move past it -- reword it, or take it back to the user.
- If `acceptance.sh` crashes rather than reporting failures, fix it before the readiness check. `workflow-readiness-check` will reject the packet otherwise.
- If the intended write scope overlaps with another active workflow, flag the conflict in the dossier's Dependencies section and in `active-workflows.md`. Ask the user whether to proceed.
- If you cannot determine the correct workflow type, ask the user. Do not default to `ft_` as a guess.

---
name: workflow-refine
description: |
  Turn rough user input into an autonomy-ready brief. Use when the user
  describes work that is vague, incomplete, or needs clarification before it can
  become a workflow packet. Asks clarifying questions, proposes concrete options,
  and produces a structured brief for workflow-create.
---

# workflow-refine

## Purpose

Turn rough user input (a verbal request, a seed file, a chat excerpt, or a vague idea) into an autonomy-ready brief or draft dossier. This is the most common user entry point for creating new work. The output should be specific enough that `workflow-create` can produce a complete packet without further clarification.

## Preconditions

- The user has provided some form of work request (typed input, a seed file, or a pointer to one).
- If the input references a seed file, it exists in `.agents/workflows/seeds/`.

## Required Reads

1. The user's raw input or the seed file at `.agents/workflows/seeds/<name>.md`.
2. `.agents/workflows/dossier-template.md` -- know what fields a finished dossier requires.
3. `.agents/pm/pm-index.md` -- check for relevant project context that should inform the brief.
4. `.agents/state/active-workflows.md` -- check for overlap with existing work.

## Procedure

1. Read the raw input. Identify the core intent: what does the user want accomplished?
2. Classify the likely workflow type prefix: `rf_` (refactor), `ft_` (feature), `iv_` (investigation), `rv_` (review), `pf_` (performance).
3. Identify ambiguities, missing information, and implicit assumptions. For each gap, determine whether you can resolve it from PM/context or must ask the user.
4. If critical information is missing (objective is unclear, success criteria cannot be inferred, scope is unbounded), ask the user focused clarifying questions. Batch questions -- do not ask one at a time.
5. Where the user faces a design choice, propose concrete options with tradeoffs rather than open-ended questions.
6. Draft a refined brief containing at minimum:
   - A one-sentence objective.
   - Proposed workflow type and ID (e.g., `rf_extract-auth-module`).
   - Acceptance criteria (observable, testable conditions).
   - Scope and non-goals.
   - Known constraints or dependencies.
   - Failure policy (what to do if the work cannot be completed).
7. Present the brief to the user for confirmation or further refinement.

## Output

- **Location**: Present the refined brief directly to the user in the conversation. If the user confirms, the brief feeds into `workflow-create`.
- **Format**: Markdown. Use the dossier template section names so the brief maps directly to packet creation.
- If the input was a seed file, note which seed it originated from so it can be archived or deleted after packet creation.

## Completion Criteria

- The refined brief contains an unambiguous objective, at least one testable acceptance criterion, explicit non-goals, and a failure policy.
- The user has confirmed the brief or explicitly handed it off to `workflow-create`.
- No open questions remain that would block autonomous execution.

## Error Handling

- If the user's input is too vague to form even a tentative objective after one round of clarifying questions, say so and ask the user to describe the desired end state.
- If the proposed work overlaps with an active workflow found in `active-workflows.md`, flag the overlap and ask the user how to proceed (merge, depend, or separate).
- Do not silently guess at acceptance criteria. If you cannot infer them, ask.

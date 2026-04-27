---
name: decision-workflow
description: |
  Create a structured decision workflow for design-heavy repositories. Use when
  the user needs to compare options with tradeoff analysis, assign a decision
  owner, and track consequences. Produces a DW-NNN document with options, pros,
  cons, and tradeoff analysis.
---

# decision-workflow

## Purpose

Produce a decision document that records a pending or completed design decision with enough structure that future readers understand what was decided, why, what was rejected, and what consequences follow.

## Required Reads

- `.agents/project.json` -- confirm design facet is enabled
- `.agents/pm/pm-decisions.md` -- existing project decisions for context and to avoid duplication
- `docs/` directory listing -- locate related design documents
- `.agents/pm/pm-current-state.md` -- understand current project state

## Procedure

1. Ask the user to describe the decision topic. Collect: the question being decided, the context or trigger, and the decision owner (person or role responsible for the final call).
2. Generate a decision ID using the format `DW-<NNN>` where NNN is the next sequential number based on existing decisions in `docs/decisions/`.
3. Create the decision file at `docs/decisions/DW-<NNN>-<slug>.md`.
4. Write the document with these sections:
   - **Status**: one of `proposed`, `accepted`, `superseded`, `rejected`.
   - **Context**: what prompted this decision and why it matters now.
   - **Options**: list each option with a description, pros, and cons.
   - **Tradeoff Analysis**: compare options on the dimensions that matter (cost, risk, complexity, reversibility).
   - **Decision**: the chosen option (leave blank if status is `proposed`).
   - **Decision Owner**: who makes or made the final call.
   - **Rationale**: why this option was chosen over the alternatives.
   - **Consequences**: what changes, follow-up work, or constraints result from this decision.
   - **Open Questions**: anything unresolved.
5. If a `docs/decisions/` directory does not exist, create it.
6. Update `docs/decisions/index.md` (create if missing) to list the new decision.
7. If the decision is accepted, add a summary entry to `.agents/pm/pm-decisions.md`.
8. Present the draft to the user for review.

## Output

- Decision document: `docs/decisions/DW-<NNN>-<slug>.md`
- Updated `docs/decisions/index.md`
- Updated `.agents/pm/pm-decisions.md` (if decision is accepted)

## Completion Criteria

- The decision document contains all required sections.
- At least two options are described with pros and cons.
- The document is listed in the decisions index.
- The status field is set correctly.

## Error Handling

- If the design facet is not enabled, warn the user and ask whether to proceed.
- If a decision with the same topic already exists, show it to the user and ask whether to update the existing record or create a new one.
- If the user cannot identify at least two options, note this gap explicitly and set status to `proposed` with an open question about alternatives.

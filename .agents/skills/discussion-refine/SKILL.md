---
name: discussion-refine
description: |
  Turn a rough design discussion into a structured written brief. Use when the
  user has unstructured notes, chat logs, or conversation fragments that need
  to become a clear document with positions, open questions, and decision
  points.
---

# discussion-refine

## Purpose

Take unstructured design discussion input (conversation notes, chat logs, rough bullet points, or a verbal description) and produce a focused written brief that a future session can act on without re-reading the original discussion.

## Required Reads

- The source discussion material (provided by the user as text, a file path, or pasted content)
- `.agents/pm/pm-current-state.md` -- understand what the project is working on
- `.agents/pm/pm-decisions.md` -- check for prior decisions relevant to the discussion
- Related design documents if referenced in the discussion

## Procedure

1. Read the source discussion material in full.
2. Identify the core topic and objective. State it in one sentence.
3. Extract distinct positions, proposals, or options mentioned in the discussion.
4. For each position, capture:
   - What it proposes.
   - Arguments in favor.
   - Arguments against or concerns raised.
   - Who advocated for it (if identifiable).
5. List explicit open questions -- points where the discussion did not reach agreement or where information is missing.
6. List decision points -- places where a choice must be made before work can proceed.
7. Note any constraints or assumptions that were stated or implied.
8. Write the refined brief with these sections:
   - **Topic**: one-line summary.
   - **Objective**: what the discussion is trying to resolve.
   - **Summary of Positions**: structured list from step 4.
   - **Open Questions**: from step 5.
   - **Decision Points**: from step 6.
   - **Constraints and Assumptions**: from step 7.
   - **Recommended Next Step**: what should happen next to move toward a decision.
9. Save the brief to a location agreed with the user. Default: `docs/briefs/<slug>.md`.
10. Present the brief to the user and ask whether any positions were missed or mischaracterized.

## Output

- Refined brief document: `docs/briefs/<slug>.md` (or user-specified location)
- Format: markdown with the sections listed above

## Completion Criteria

- Every distinct position from the source material is represented.
- Open questions are explicit, not buried in prose.
- Decision points are actionable (a reader can tell what needs to be decided).
- The brief is self-contained -- a reader does not need the original discussion to understand it.

## Error Handling

- If the source material is too short or vague to extract meaningful positions, tell the user and ask for more context.
- If the discussion references decisions already recorded in `pm-decisions.md`, link to them rather than restating.
- If the user disagrees with how a position was characterized, revise the brief before saving.

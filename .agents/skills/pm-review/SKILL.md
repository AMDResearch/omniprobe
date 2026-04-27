---
name: pm-review
description: |
  Create or manage a review workflow packet. Use when the user wants a
  structured code, design, or document review with severity-categorized findings,
  file-level traceability, and verification gap identification.
---

# pm-review

## Purpose

Create or manage a review workflow packet. Reviews evaluate existing code, documents, or designs and produce structured findings with severity, clear file references, and actionable recommendations. This skill emphasizes completeness of coverage, verification gap identification, and traceability of findings to source.

## Required Reads

1. `.agents/workflows/INDEX.md` -- understand lifecycle states and packet structure.
2. `.agents/workflows/dossier-template.md` -- the dossier format to follow.
3. `.agents/pm/pm-current-state.md` -- check for related workflows and known risks.
4. Relevant PM units for the area under review (via pm-load).

## Procedure

### Creating a new review packet

1. **Choose the workflow ID.** Use the prefix `rv_` followed by a short descriptive slug. Example: `rv_auth_module_security`.
2. **Create the packet directory.** Path: `.agents/workflows/draft/rv_<slug>/`.
3. **Write `dossier.md`.** Copy the structure from `dossier-template.md` and fill in:
   - Metadata: set Workflow Type to "review", Lifecycle State to "draft".
   - Objective: state what is being reviewed and the review goal. Example: "Review the authentication module for security vulnerabilities and test coverage gaps."
   - Background/Context: explain why this review is happening (new code, incident follow-up, periodic audit, pre-release check).
   - Contract: define what a complete review delivers. Example: "All files in scope examined, findings categorized by severity, verification gaps identified, recommendations provided."
   - Acceptance Criteria:
     - Every file in scope has been read and assessed.
     - Each finding includes: severity (critical / high / medium / low / info), file path and line range, description, and recommendation.
     - Verification gaps are listed (areas with no tests, no docs, or unclear behavior).
     - A summary with overall assessment and prioritized action items.
   - Failure Policy: "If scope is too large to review in one session, document progress, list unreviewed files, and hand off."
   - Scope: list every file and directory to be reviewed. Be explicit -- do not use vague scopes like "the backend."
   - Verification Strategy: describe how findings will be confirmed (reproduce the issue, write a test, check against a specification).
4. **Write `run-log.md`.** Initialize from `run-log-template.md`. Review run-logs should record each file examined, time spent, and findings per file.
5. **Write `handoff.md`.** Initialize from `handoff-template.md`. Set "Next Exact Step" to the first file or area to review.
6. **Write `artifacts.md`.** Initialize from `artifacts-template.md`. This will hold the structured findings table and summary.
7. **Update `.agents/workflows/INDEX.md`** if a tracking table is maintained.

### Managing an existing review packet

1. **For each file or area reviewed**, append a run-log entry: file path, what was checked, findings (or "no issues found"), and verification status.
2. **Record findings in `artifacts.md`** using this format per finding:
   ```
   ### Finding: <short title>
   - Severity: critical | high | medium | low | info
   - Location: <file path>:<line range>
   - Description: <what the issue is>
   - Evidence: <how you confirmed it>
   - Recommendation: <what to do about it>
   ```
3. **Track coverage.** Maintain a checklist in `handoff.md` or `artifacts.md` showing which files have been reviewed and which remain.
4. **Update `handoff.md`** after every review session with files remaining and any new risks discovered.
5. **When concluding**, write a summary in `artifacts.md` with: total files reviewed, finding counts by severity, top 3 priority actions, and overall assessment.
6. **Move the packet to done** when all files in scope have been reviewed and findings are documented. If reviews are partial, leave as active or suspended with clear handoff.

## Output

- `.agents/workflows/draft/rv_<slug>/dossier.md`
- `.agents/workflows/draft/rv_<slug>/run-log.md`
- `.agents/workflows/draft/rv_<slug>/handoff.md`
- `.agents/workflows/draft/rv_<slug>/artifacts.md`

## Completion Criteria

- All four packet files exist and follow their respective templates.
- The scope lists specific files or directories, not vague descriptions.
- The findings format includes severity, file path with line range, and recommendation.
- Verification gaps (untested code, missing docs) are called out separately from code issues.
- A summary with prioritized action items exists in artifacts when the review is complete.

## Error Handling

- If the review scope is too large for one session, review the highest-risk files first, document progress in `handoff.md`, and list unreviewed files explicitly so the next session can continue.
- If a file in scope has been deleted or moved since the review was scoped, note it in the run-log and remove it from the remaining checklist.
- If findings conflict with recorded PM knowledge (e.g., PM says "module X has full test coverage" but the review finds gaps), flag the discrepancy and update PM via pm-update after the review concludes.

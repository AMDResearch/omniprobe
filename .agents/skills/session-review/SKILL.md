---
name: session-review
description: |
  Review session captures and extract process improvements. Use when the user
  says "review session", "session review", or when session-capture recommends a
  review (typically every 5 captures). Identifies failure modes, positive
  patterns, and drafts local proposals or forward-to-meta lessons.
---

# session-review

## Purpose

Turn raw session history into structured improvement artifacts. This skill reads a session capture, identifies what went well and what failed, produces a review artifact, and optionally drafts a local proposal or a forward-to-meta lesson.

## Preconditions

- A session capture exists at `.untracked/session-captures/<timestamp>-<agent>.md`.
- The agent has the capture file path (provided by the user or by the session-capture skill).

## Required Reads

1. The session capture file (path provided as input).
2. `.agents/improvement/failure-modes.md` -- existing known failure patterns.
3. `.agents/policy/contract.md` -- to check for contract violations.
4. `.agents/docs/user/session-review-and-improvement.md` -- review process rules.
5. The workflow `dossier.md` for any workflow the session worked on (to compare intent vs. outcome).

## Procedure

1. **Parse the session capture.** Extract: session goal, files touched, commands run, tests run, blockers encountered, and unresolved follow-ups.
2. **Assess goal completion.** Was the stated session goal met? Partially met? Not met? Cite specific evidence from the capture.
3. **Identify failure modes.** Look for these categories:
   - Contract violations (acceptance criteria changed without approval).
   - Scope drift (work done outside the workflow's write scope).
   - Over-reading (excessive PM or file loading beyond what the task required).
   - Under-documentation (no handoff written, no run-log entry, no session capture).
   - Silent failure (errors encountered but not reported or escalated).
   - Defective verification instrument -- a test, gate, scan pattern, mutation check, or
     heuristic that produced a result indistinguishable from a correct one without having been
     exercised against the condition it exists to detect. Distinct from silent failure: that is
     an error not reported, this is a success that was not earned.
     An instrument that has not been exercised against the condition it detects has not been verified.
     Look for a check that passed before the work it checks was done, a control that was described
     but never run, and a clean result that is also what a broken instrument would print.
4. **Check against known patterns.** Compare findings to `.agents/improvement/failure-modes.md`. Note if a known pattern recurred or if a new pattern emerged.
5. **Identify positive patterns.** Note effective practices worth reinforcing (e.g., minimal PM loading, clean handoff, good test coverage).
6. **Draft local proposal (if warranted).** If a process change would prevent a failure mode found in this session, draft a proposal. Only draft if the improvement is concrete and actionable.
7. **Update failure-modes.md (if warranted).** If any process failure was identified during the session that is not already in `.agents/improvement/failure-modes.md`, append it as `FM-L<n>` -- the next free number in this project's own `FM-L` sequence, counting from 1 -- with description, impact, and suggested mitigation, using the structured format in that file. A bare `FM-<n>` belongs to the framework; see the namespace rule at the top of `failure-modes.md`.
8. **Draft forward-to-meta lesson (if warranted).** If the finding generalizes beyond this specific project, draft a forwarding artifact. See `lessons-forward` skill for criteria.

## Output

### Session Review (always produced)

Write to `.agents/improvement/session-reviews/<date>-<agent>-review.md`:

```markdown
# Session Review

**Date:** YYYY-MM-DD
**Capture:** <path to session capture>
**Workflow:** <workflow-id or "none">

## Goal Completion
<met | partial | not met> -- <1-sentence explanation>

## Failure Modes Found
- <category>: <specific description>

## Known Pattern Recurrences
- <pattern from failure-modes.md> -- <how it recurred>

## New Patterns
- <description of new failure pattern>

## Positive Patterns
- <what worked well>

## Recommendations
- <concrete suggestion>
```

### Local Proposal (only if warranted)

Write to `.agents/improvement/local-proposals/<date>-<slug>.md`:

```markdown
# Proposal: <title>

**Origin:** session review <date>
**Problem:** <what went wrong>
**Proposed Change:** <specific change to a specific file>
**Expected Benefit:** <what improves>
**Risk:** <what could go wrong>
```

### Forward-to-Meta Lesson (only if warranted)

Write to `.agents/improvement/forward-to-meta/<date>-<slug>.md` using the format defined in the `lessons-forward` skill.

## Batch Review Mode

When reviewing multiple captures at once, use this streamlined procedure instead of the
full per-capture review. Five is the *trigger* threshold — the point at which a review is
recommended — not a cap on how many captures a review covers. A batch review always covers
the entire unreviewed backlog, however large it has grown.

1. **Read every unreviewed session capture.** Find the most recent file in
   `.agents/improvement/session-reviews/` (excluding `README.md`); every capture in
   `.untracked/session-captures/` newer than it is unreviewed. If no review exists, every
   capture is unreviewed. Read all of them, oldest first, so the chronology is visible.
   If the backlog is large enough that reading it all at once would exhaust context, read
   in oldest-first batches and carry forward a running list of candidate patterns rather
   than truncating the set — dropping the oldest captures loses exactly the long-running
   patterns a batch review exists to find. Say in the review if this was necessary.
2. **Identify the top friction pattern** across all captures — the single most recurring
   source of wasted time, confusion, or rework.
3. **Identify one positive pattern** worth reinforcing.
4. **Check against `failure-modes.md`** — is the friction pattern already known? If not,
   add it as a new `FM-L<n>` entry.
5. **Write a single batch review file** to `.agents/improvement/session-reviews/<date>-batch-review.md`:

   ```markdown
   # Batch Session Review

   **Date:** YYYY-MM-DD
   **Captures reviewed:** <list of every capture filename covered, oldest first>

   ## Top Friction Pattern
   <1-2 sentences describing the pattern and specific evidence from captures>

   ## Positive Pattern
   <1 sentence on what worked well>

   ## Action Taken
   - [ ] Added to failure-modes.md as FM-<N> (if new)
   - [ ] Drafted local proposal (if actionable) — see local-proposals/<date>-<slug>.md
   - [ ] No action needed (pattern is known and already mitigated)
   ```

6. **Draft a local proposal** only if the friction pattern is actionable and not already
   mitigated. Keep the proposal under 15 lines.

## Completion Criteria

- A session review file has been written with all sections filled.
- Every failure mode is categorized and described with specific evidence.
- Local proposals (if any) reference a specific file and a specific change.
- The approval boundary is respected: no process or policy files were modified.
- For batch reviews: a single review file covers the entire unreviewed backlog — no capture
  older than the review is left uncovered — and the top friction pattern is specific and
  evidence-based.

## Error Handling

- If the session capture file does not exist at the given path, stop: "Session capture not found at <path>. Run session-capture first."
- If the capture is too sparse to review (fewer than 3 substantive lines), write a minimal review noting "Capture insufficient for meaningful review" and stop.
- If the workflow dossier cannot be found, skip goal-completion assessment against acceptance criteria and note it was skipped.
- When updating `failure-modes.md`, assign the next free `FM-L<n>` -- local to this repository, counting from 1 -- and use the structured format defined in that file. Never mint a bare `FM-<n>`: that namespace is the framework's, and a client that takes the next number in it collides with whatever the framework defines there later.

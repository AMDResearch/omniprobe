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
4. **Check against known patterns.** Compare findings to `.agents/improvement/failure-modes.md`. Note if a known pattern recurred or if a new pattern emerged.
5. **Identify positive patterns.** Note effective practices worth reinforcing (e.g., minimal PM loading, clean handoff, good test coverage).
6. **Draft local proposal (if warranted).** If a process change would prevent a failure mode found in this session, draft a proposal. Only draft if the improvement is concrete and actionable.
7. **Update failure-modes.md (if warranted).** If any process failure was identified during the session that is not already in `.agents/improvement/failure-modes.md`, append it with a unique ID (FM-N), description, impact, and suggested mitigation using the structured format in that file.
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

When reviewing multiple captures at once (recommended cadence: every 5 captures), use
this streamlined procedure instead of the full per-capture review:

1. **Read the last 5 session captures** (or since the last review, whichever is fewer).
2. **Identify the top friction pattern** across all captures — the single most recurring
   source of wasted time, confusion, or rework.
3. **Identify one positive pattern** worth reinforcing.
4. **Check against `failure-modes.md`** — is the friction pattern already known? If not,
   add it as a new FM-N entry.
5. **Write a single batch review file** to `.agents/improvement/session-reviews/<date>-batch-review.md`:

   ```markdown
   # Batch Session Review

   **Date:** YYYY-MM-DD
   **Captures reviewed:** <list of capture filenames>

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
- For batch reviews: a single review file covers all captures reviewed; the top friction
  pattern is specific and evidence-based.

## Error Handling

- If the session capture file does not exist at the given path, stop: "Session capture not found at <path>. Run session-capture first."
- If the capture is too sparse to review (fewer than 3 substantive lines), write a minimal review noting "Capture insufficient for meaningful review" and stop.
- If the workflow dossier cannot be found, skip goal-completion assessment against acceptance criteria and note it was skipped.
- When updating `failure-modes.md`, assign a unique sequential ID (FM-N) and use the structured format defined in that file.

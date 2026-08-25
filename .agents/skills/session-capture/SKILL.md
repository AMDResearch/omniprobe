---
name: session-capture
description: |
  Create a normalized session capture file preserving what happened in a session.
  Use at the end of a work session, or when the user says "capture session" or
  "save session". Records session goal, work performed, decisions, blockers, and
  verification results to .untracked/session-captures/.
---

# session-capture

## Purpose

Create a normalized session capture file when raw transcripts are not available or are impractical to store. This preserves the essential facts of what happened in a session so future sessions and reviews can learn from it without needing the full conversation history.

## Preconditions

- A work session has just ended or is about to end.
- The agent has context about what was done during the session (from memory or from run-log entries).

## Required Reads

1. `.agents/state/active-workflows.md` -- identify which workflow(s) were touched, if any.
2. If a workflow was active: `.agents/workflows/<state>/<workflow-id>/run-log.md` -- cross-reference what was logged vs. what needs to be captured.
3. `.agents/pm/pm-index.md` -- check whether any session findings warrant a PM update (do not update PM here, just note the need).

## Procedure

1. **Determine the capture filename.** Format: `<YYYY-MM-DD-HHMM>-<agent-identifier>.md`. Example: `2026-04-12-1430-claude.md`.
2. **Create the file** at `.untracked/session-captures/<filename>`.
3. **Write the following sections in order:**

   **Session Metadata**
   - Date and approximate time range.
   - Agent identifier (e.g., `claude`, `codex`, or a custom name).
   - Associated workflow ID(s), or `none` if ad-hoc work.
   - Mode: `standard` or `sidecar` (if `project.json` contains `"sidecar": true`, note
     the target repo path and include the target repo's current git branch and HEAD commit).

   **Session Goal**
   - One or two sentences: what was this session trying to accomplish?

   **Work Performed**
   - Bulleted list of actions taken. Be specific: name files created, modified, or deleted. Name commands run and their outcomes.

   **Verification**
   - What was tested or checked. Include pass/fail results.
   - If nothing was verified, state: `No verification performed this session.`

   **Decisions Made**
   - Any design decisions, trade-off resolutions, or user approvals captured during the session.
   - If none, state: `No significant decisions this session.`

   **Blockers and Open Items**
   - Anything that blocked progress or remains unresolved.
   - Items that need follow-up in the next session.

   **PM Update Needed**
   - `Yes` or `No`. If yes, briefly state what should be updated (but do not update PM in this skill).

4. **If a workflow was active**, ensure the workflow's `handoff.md` has also been updated before ending the session. The session capture supplements the handoff -- it does not replace it.
5. **Run-log check.** If a workflow was active and `run-log.md` has no entries from this session, append a summary entry before completing the capture. The run-log should never be empty for a session that did meaningful work.
6. **Check review cadence.** After writing the capture file:
   a. Find the most recent session review file in `.agents/improvement/session-reviews/`
      (exclude `README.md`). If there is none, every capture is unreviewed.
   b. **List** the capture files in `.untracked/session-captures/` that are newer than that
      review, then count the list. Call this N. Do not infer N from review *count* — a batch
      review covers the whole backlog it found, not a fixed number of captures — and do not
      arrive at N by adding one to a remembered figure. Both shortcuts have produced a
      mis-stated N in a step whose own instruction is to derive it from timestamps.

   c. **Count the declines.** Of those same captures, count how many already carry a review
      recommendation footer. Call this D. This is the signal the plain count misses: a
      recommendation declined several times over is evidence that it should fire *less often*
      or be *harder to skip*, not that it should keep firing unchanged.

      Counting footers rather than tracking consecutiveness is deliberate. "Three in a row"
      breaks the moment a capture is written outside a normal session; "how many unreviewed
      captures asked for a review" survives that and answers the same question.

   d. **Check whether a packet is in flight.** If any directory exists under
      `.agents/workflows/active/`, a workflow is mid-execution.

      **Suppress the standing recommendation while one is**, unless the ceiling in (g) applies.
      Stopping mid-packet to review process is disruptive and reviews an unfinished story; the
      cheapest and most informative moment is the first close after `active/` empties. Emit the
      deferred form instead:

      ```
      ---
      **Review due on completion.** There are <N> unreviewed session captures, and
      <workflow-id> is still in `active/`. A batch review is most useful once the packet
      completes — it can then see the whole execution rather than a fragment. Run
      `/session-review` at the first close after `active/` empties.
      ```

   e. If `active/` is empty and N >= 5, append the standing recommendation:

      ```
      ---
      **Review recommended.** There are <N> unreviewed session captures. Run `/session-review`
      in batch mode to extract improvement opportunities. It covers all <N>, not just the
      most recent five — five is only the threshold at which a review is worth running.
      ```

   f. **Escalate on repetition, not on an absolute count.** If D >= 3 — three or more
      unreviewed captures already asked for a review and it has not happened — append this
      instead of (e), naming the decline count. Compute the span from the oldest unreviewed
      capture's date to today:

      ```
      ---
      **Review overdue.** <N> session captures have gone unreviewed across <span> days, and
      <D> of them already recommended a review. The recommendation has been declined <D>
      times; repeating it unchanged is not the remedy. Cross-session patterns — the thing a
      batch review exists to find — stay invisible until it runs. Run `/session-review` in
      batch mode before starting new work this session.
      ```

      An absolute threshold is not used here because it does not measure what matters. A
      count is a proxy for elapsed time and stops being one during a burst: nine captures in
      28 hours reads as "across 2 days", which sounds fine. Neither the count nor the span
      carries the signal. The repetition does.

   g. **The suppression has a ceiling.** If the oldest unreviewed capture is more than 14 days
      old, (d) no longer suppresses — emit (e) or (f) even while a packet is active, and add:
      "Suppression no longer applies: the backlog is older than 14 days." A packet that runs
      for weeks must not defer the review for weeks with it.

   h. Also include the recommendation in the agent's response to the user, matching whichever
      of (d), (e) or (f) fired:
      - deferred: "Note: <N> captures are unreviewed, but <workflow-id> is still active. A
        review is due at the first close after it completes."
      - recommended: "Note: <N> session captures have accumulated without review. Consider
        running `/session-review` to extract process improvements."
      - overdue: "Note: <N> captures span <span> days and <D> of them already asked for a
        review. Run `/session-review` in batch mode before new work."

## Output

- **Location**: `.untracked/session-captures/<YYYY-MM-DD-HHMM>-<agent>.md`
- **Format**: Markdown with the sections listed above. Keep the total length under 80 lines. Capture facts, not commentary.

## Completion Criteria

- The session capture file exists at the correct path with the correct filename format.
- All seven sections are present, even if some say "none" or "N/A."
- If a workflow was active, `handoff.md` has been updated separately.
- The capture contains only factual observations, not opinions or speculation.

## Error Handling

- If `.untracked/session-captures/` does not exist, create the directory.
- If you cannot determine what was done in the session (no memory, no run-log), write a minimal capture stating: `Session content could not be reconstructed. Manual review recommended.` Do not fabricate session history.
- If the session involved multiple workflows, create one capture file covering all of them rather than separate files per workflow.

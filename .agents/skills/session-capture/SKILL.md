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
   a. Count the number of session capture files in `.untracked/session-captures/`.
   b. Count the number of session review files in `.agents/improvement/session-reviews/`
      (exclude `README.md`).
   c. If (captures - reviews * 5) >= 5, append to the capture file:

      ```
      ---
      **Review recommended.** There are <N> unreviewed session captures. Run `/session-review`
      on the last 5 captures to extract improvement opportunities.
      ```

   d. Also include this recommendation in the agent's response to the user:
      "Note: <N> session captures have accumulated without review. Consider running
      `/session-review` to extract process improvements."

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

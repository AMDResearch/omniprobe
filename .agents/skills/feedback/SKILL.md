---
name: feedback
description: |
  Collect user feedback about the Agentic Meta Project and file it. Use when the
  user says "feedback", "report a bug", "file an issue", or wants to report
  friction, suggestions, or feature requests. Files as a GitHub issue if gh CLI
  is available, otherwise writes a local report.
---

# feedback

## Purpose

Provide a structured way for users to report bugs, friction, suggestions, or feature requests back to the meta-project maintainers. This closes the feedback loop between real-world usage and template improvements.

## Preconditions

- The user wants to report an issue, suggestion, or friction point.

## Procedure

1. **Ask the user for feedback type.** Options: bug, friction, suggestion, feature request.
2. **Collect a description.** Ask the user to describe the issue. Include:
   - What happened (or what they want).
   - Steps to reproduce (if applicable).
   - What they expected instead.
3. **Gather context.** Note the following automatically (ask the user before including project-specific details):
   - Client project name (anonymize if the user requests).
   - Amplify version from `.agents/project.json`.
   - Which skills/workflows were involved (if applicable).
4. **Check if `gh` CLI is available.** Run `gh auth status` to verify.
5. **If `gh` is available**: create a GitHub issue on the meta-project repository with:
   - Title: `[<feedback-type>] <short summary>`
   - Labels: `feedback`, `<feedback-type>`
   - Body:
     ```
     ## Feedback Type
     <bug | friction | suggestion | feature request>

     ## Description
     <user's description>

     ## Reproduction Steps
     <steps, or "N/A">

     ## Context
     - Amplify version: <version>
     - Project type: <type>
     - Skills involved: <list or "none">

     ## Expected Behavior
     <what the user expected>

     ---
     Filed via `/feedback` skill.
     ```
   - Confirm the issue URL with the user.
6. **If `gh` is not available**: write the report to `.untracked/feedback/<YYYY-MM-DD>-<summary-slug>.md` using the same format. Tell the user where the file is and how to file it manually.

7. **Update feedback index.** Append a row to `.untracked/feedback/feedback-index.md`:
   `| <YYYY-MM-DD> | <short summary> | <feedback-type> | open | <filename or issue-URL> |`
   If `feedback-index.md` does not exist, create it with the header row first.

## Output

- **If `gh` available**: a GitHub issue URL.
- **If `gh` unavailable**: a local file at `.untracked/feedback/<YYYY-MM-DD>-<summary-slug>.md`.

## Completion Criteria

- Feedback type and description collected from user.
- Issue filed (GitHub) or report written (local).
- User informed of the result.

## Error Handling

- If `gh auth status` fails, fall back to local file without asking the user to authenticate.
- If the GitHub issue creation fails, fall back to local file and report the error.
- If `.untracked/feedback/` does not exist, create it.

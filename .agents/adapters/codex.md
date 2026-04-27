# Codex Adapter

## Skill Discovery

Codex does not have a native slash-command mechanism. To use skills:

1. Read `.agents/bootstrap/installed-skills.md` for the full skill catalog with usage triggers.
2. To invoke a skill, read `.agents/skills/<skill-name>/SKILL.md` and follow its procedure
   as task-specific instructions.
3. Key skills to read at session start: `session-init`, then follow its procedure.

## Session Capture

Codex sessions should produce session captures using the same format as other agents:
- File location: `.untracked/session-captures/<YYYY-MM-DD-HHMM>-codex.md`
- Follow the procedure in `.agents/skills/session-capture/SKILL.md`.

## Write Scope

Codex has the same write permissions as other agents within `.agents/` and project source
directories. If the runtime environment restricts writes to `.agents/`:
- Stage artifacts under `.untracked/scratch/<workflow-id>/` as a fallback.
- Note the fallback location in the workflow run-log so the primary agent can integrate them.
- File a feedback report noting the write restriction.

## Reporting Style

- Use concise plans and explicit verification.
- Summarize command outputs rather than pasting full terminal output.
- When producing review reports or artifacts, follow the same format as specified in
  the relevant skill's Output section.

## Coordination with Other Agents

- Check `.agents/state/active-workflows.md` for write-scope assignments before modifying files.
- If working on a shared workflow (e.g., multi-agent review), maintain a separate run-log
  file: `run-log-codex.md` in the workflow directory.
- Do not read the other agent's run-log or review artifacts until the coordination plan says
  to (e.g., during synthesis phases).

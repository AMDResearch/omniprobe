# Amplify Installation Report

## Project

- Project: `omniprobe`
- Inferred primary type: `code`
- Inferred facets: `code, design`
- Installed primary type: `code`
- Installed facets: `code, design`
- Installed skill sets: `core, code, design`
- Tracking mode: `tracked` (committed with the repo)

## Created

- `.agents/adapters`
- `.agents/bootstrap`
- `.agents/policy`
- `.agents/skills`
- `.agents/pm`
- `.agents/pm/units`
- `.agents/pm/done`
- `.agents/pm/done/README.md`
- `.agents/workflows`
- `.agents/workflows/seeds`
- `.agents/workflows/seeds/README.md`
- `.agents/workflows/draft`
- `.agents/workflows/draft/README.md`
- `.agents/workflows/active`
- `.agents/workflows/active/README.md`
- `.agents/workflows/suspended`
- `.agents/workflows/suspended/README.md`
- `.agents/workflows/blocked`
- `.agents/workflows/blocked/README.md`
- `.agents/workflows/failed`
- `.agents/workflows/failed/README.md`
- `.agents/workflows/done`
- `.agents/workflows/done/README.md`
- `.agents/workflows/abandoned`
- `.agents/workflows/abandoned/README.md`

## Skipped

- `CLAUDE.md`
- `.agents/state/current-focus.md`
- `.agents/state/active-workflows.md`
- `.claude/skills/session-init/SKILL.md`
- `.agents/pm/pm-index.md`
- `.agents/pm/pm-current-state.md`
- `.agents/pm/pm-decisions.md`
- `.agents/pm/pm-glossary.md`

## Requires User Review

- Confirm `.agents/project.json` matches the project's actual shape.
- Confirm `.agents/state/active-workflows.md` matches the workflows you actually want to run in parallel.
- Tighten the generated PM units after the first real task.
- Review policy and workflow docs before autonomous execution.

## Next Steps

1. Start your agent (e.g., `claude`) in this repo.
2. Run `/session-init` to bootstrap the agent.
3. Run `/pm-init` to build project memory from the codebase.
4. You are now ready to create workflows and start work.

For reference: `.agents/docs/user/getting-started.md` and `.agents/docs/user/how-to-work-with-an-agent.md`.

## Notes

- Preserved user state file: .agents/state/current-focus.md
- Preserved user state file: .agents/state/active-workflows.md
- Preserved user state file: .agents/pm/pm-index.md
- Preserved user state file: .agents/pm/pm-current-state.md
- Preserved user state file: .agents/pm/pm-decisions.md
- Preserved user state file: .agents/pm/pm-glossary.md
- Template feedback-index.md not found; skipped.

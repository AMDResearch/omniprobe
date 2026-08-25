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

- `.agents/hooks`
- `.agents/hooks/acceptance-lib.sh`
- `.agents/hooks/resolve-plugins.sh`
- `.agents/hooks/stop-acceptance.sh`
- `.agents/workflows/acceptance-template.sh`
- `.agents/skills/workflow-execute/SKILL.md`
- `.claude/skills/workflow-execute/SKILL.md`

## Skipped

- `.agents/improvement/failure-modes.md`
- `.agents/pm/pm-current-state.md`
- `.agents/pm/pm-decisions.md`
- `.agents/pm/pm-glossary.md`
- `.agents/pm/pm-index.md`
- `.agents/state/active-workflows.md`
- `.agents/state/current-focus.md`

## Overwritten

These 100 files existed and were replaced with the current template version. Recover any of them from git:

```
git checkout HEAD -- <path>
```

- `.agents/adapters/claude.md`
- `.agents/adapters/codex.md`
- `.agents/adapters/shared-entrypoint.md`
- `.agents/bootstrap/installed-skills.md`
- `.agents/bootstrap/reading-paths.md`
- `.agents/bootstrap/session-start.md`
- `.agents/docs/agent/pm-maintenance.md`
- `.agents/docs/agent/review-loop.md`
- `.agents/docs/agent/session-bootstrap.md`
- `.agents/docs/agent/workflow-execution.md`
- `.agents/docs/examples/bugfix-example.md`
- `.agents/docs/examples/feature-example.md`
- `.agents/docs/examples/investigation-example.md`
- `.agents/docs/examples/performance-example.md`
- `.agents/docs/examples/refactor-example.md`
- `.agents/docs/examples/review-example.md`
- `.agents/docs/user/amplify-existing-project.md`
- `.agents/docs/user/getting-started.md`
- `.agents/docs/user/how-to-work-with-an-agent.md`
- `.agents/docs/user/parallel-work.md`
- `.agents/docs/user/project-memory-overview.md`
- `.agents/docs/user/session-review-and-improvement.md`
- `.agents/docs/user/tutorials/bugfix-session.md`
- `.agents/docs/user/tutorials/feature-session.md`
- `.agents/docs/user/tutorials/investigation-session.md`
- `.agents/docs/user/tutorials/performance-session.md`
- `.agents/docs/user/tutorials/refactor-session.md`
- `.agents/docs/user/tutorials/review-session.md`
- `.agents/docs/user/workflows-overview.md`
- `.agents/pm/pm-overview.md`
- `.agents/pm/pm-usage.md`
- `.agents/pm/pm-workflows.md`
- `.agents/policy/contract.md`
- `.agents/policy/guardrails.md`
- `.agents/policy/verification.md`
- `.agents/workflows/INDEX.md`
- `.agents/workflows/artifacts-template.md`
- `.agents/workflows/dossier-template.md`
- `.agents/workflows/handoff-template.md`
- `.agents/workflows/run-log-template.md`
- `AGENTS.md` — **root adapter file.** May have held project-specific content; review this one before anything else.
- `CLAUDE.md` — **root adapter file.** May have held project-specific content; review this one before anything else.
- `.agents/skills/decision-workflow/SKILL.md`
- `.agents/skills/discussion-refine/SKILL.md`
- `.agents/skills/docs-sync/SKILL.md`
- `.agents/skills/feedback/SKILL.md`
- `.agents/skills/lessons-forward/SKILL.md`
- `.agents/skills/pm-bugfix/SKILL.md`
- `.agents/skills/pm-feature/SKILL.md`
- `.agents/skills/pm-init/SKILL.md`
- `.agents/skills/pm-investigation/SKILL.md`
- `.agents/skills/pm-load/SKILL.md`
- `.agents/skills/pm-performance/SKILL.md`
- `.agents/skills/pm-refactor/SKILL.md`
- `.agents/skills/pm-reflect/SKILL.md`
- `.agents/skills/pm-restructure/SKILL.md`
- `.agents/skills/pm-review/SKILL.md`
- `.agents/skills/pm-update/SKILL.md`
- `.agents/skills/pm-validate/SKILL.md`
- `.agents/skills/session-capture/SKILL.md`
- `.agents/skills/session-close/SKILL.md`
- `.agents/skills/session-init/SKILL.md`
- `.agents/skills/session-review/SKILL.md`
- `.agents/skills/state-check/SKILL.md`
- `.agents/skills/workflow-complete/SKILL.md`
- `.agents/skills/workflow-create/SKILL.md`
- `.agents/skills/workflow-readiness-check/SKILL.md`
- `.agents/skills/workflow-refine/SKILL.md`
- `.agents/skills/workflow-resume/SKILL.md`
- `.agents/project.json`
- `.gitignore`
- `.claude/skills/decision-workflow/SKILL.md`
- `.claude/skills/discussion-refine/SKILL.md`
- `.claude/skills/docs-sync/SKILL.md`
- `.claude/skills/feedback/SKILL.md`
- `.claude/skills/lessons-forward/SKILL.md`
- `.claude/skills/pm-bugfix/SKILL.md`
- `.claude/skills/pm-feature/SKILL.md`
- `.claude/skills/pm-init/SKILL.md`
- `.claude/skills/pm-investigation/SKILL.md`
- `.claude/skills/pm-load/SKILL.md`
- `.claude/skills/pm-performance/SKILL.md`
- `.claude/skills/pm-refactor/SKILL.md`
- `.claude/skills/pm-reflect/SKILL.md`
- `.claude/skills/pm-restructure/SKILL.md`
- `.claude/skills/pm-review/SKILL.md`
- `.claude/skills/pm-update/SKILL.md`
- `.claude/skills/pm-validate/SKILL.md`
- `.claude/skills/session-capture/SKILL.md`
- `.claude/skills/session-close/SKILL.md`
- `.claude/skills/session-init/SKILL.md`
- `.claude/skills/session-review/SKILL.md`
- `.claude/skills/state-check/SKILL.md`
- `.claude/skills/workflow-complete/SKILL.md`
- `.claude/skills/workflow-create/SKILL.md`
- `.claude/skills/workflow-readiness-check/SKILL.md`
- `.claude/skills/workflow-refine/SKILL.md`
- `.claude/skills/workflow-resume/SKILL.md`
- `.untracked/feedback/feedback-index.md`
- `.agents/bootstrap/amplify-installation-report.md`

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

- Proceeded with 569 uncommitted path(s) outside the write set: `build_v3.6.0_llvm/CMakeCache.txt`, `build_v3.6.0_llvm/CMakeFiles/3.25.2/CMakeCXXCompiler.cmake`, `build_v3.6.0_llvm/CMakeFiles/3.25.2/CMakeDetermineCompilerABI_CXX.bin`, `build_v3.6.0_llvm/CMakeFiles/3.25.2/CMakeDetermineCompilerABI_HIP.bin`, `build_v3.6.0_llvm/CMakeFiles/3.25.2/CMakeHIPCompiler.cmake`, `build_v3.6.0_llvm/CMakeFiles/3.25.2/CMakeSystem.cmake`, `build_v3.6.0_llvm/CMakeFiles/3.25.2/CompilerIdCXX/CMakeCXXCompilerId.cpp`, `build_v3.6.0_llvm/CMakeFiles/3.25.2/CompilerIdCXX/a.out`, `build_v3.6.0_llvm/CMakeFiles/3.25.2/CompilerIdHIP/CMakeHIPCompilerId.hip`, `build_v3.6.0_llvm/CMakeFiles/3.25.2/CompilerIdHIP/a.out` ...
- Preserved user state file: .agents/improvement/failure-modes.md
- Preserved user state file: .agents/pm/pm-current-state.md
- Preserved user state file: .agents/pm/pm-decisions.md
- Preserved user state file: .agents/pm/pm-glossary.md
- Preserved user state file: .agents/pm/pm-index.md
- Preserved user state file: .agents/state/active-workflows.md
- Preserved user state file: .agents/state/current-focus.md
- Skipped pm-init because --no-pm-init was passed.
- Backfilled pm-index Type and Always-Load columns.
-   architecture: type=arch-overview, always-load=false
-   build-system: type=code-nav, always-load=false
-   interceptor: type=code-nav, always-load=false
-   handler-pipeline: type=code-nav, always-load=false
-   memory-analysis: type=code-nav, always-load=false
-   omniprobe-cli: type=code-nav, always-load=false
-   instrumentation: type=code-nav, always-load=false
-   sub-dh-comms: type=code-nav, always-load=false
-   sub-kerneldb: type=code-nav, always-load=false
-   testing: type=infra, always-load=false
-   Always-Load candidate: `architecture` is typed `arch-overview` but its Always-Load is `false`. To load it in every session, set the `Always-Load` column to `true` for that row in `.agents/pm/pm-index.md`.
- Failure-mode ids outside the framework namespace (reported only; nothing was changed): FM-4

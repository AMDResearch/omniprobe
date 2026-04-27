# Project Decisions

Durable project decisions with rationale. Updated by `pm-update` after each workflow.

| Date | Decision | Rationale | Source |
|------|----------|-----------|--------|
| 2026-04-27 | `.claude/skills/` wrappers are thin delegates to `.agents/skills/` | Prevents fork divergence from upstream template; project-local augmentation (env vars, priming) stays in wrapper pre-step | session (v0.3 migration) |
| 2026-04-27 | `cleanroom-test` canonical location is `.agents/skills/cleanroom-test/` | Project-local skill, not from template; moved from `.claude/skills/` for consistency | session (v0.3 migration) |
| 2026-04-27 | Filed feedback: local augmentation mechanism for generic skills (GH issue #1) | No clean hook for project-local steps in template skills; proposed LOCAL.md overlay | session (v0.3 migration) |
| 2026-04-27 | Merge `plugins` + `comms-mgr` PM units into `handler-pipeline` | Tightly coupled, always loaded together; merged unit better reflects code boundary | pm-restructure |
| 2026-04-27 | Create `build-system` PM unit (extracted from `architecture` + `instrumentation`) | CMake config, install layout, and env vars were scattered; centralized for build-focused tasks | pm-restructure |

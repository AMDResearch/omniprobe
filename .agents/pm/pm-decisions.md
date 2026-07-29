# Project Decisions

Durable project decisions with rationale. Updated by `pm-update` after each workflow.

| Date | Decision | Rationale | Source |
|------|----------|-----------|--------|
| 2026-04-27 | `.claude/skills/` wrappers are thin delegates to `.agents/skills/` | Prevents fork divergence from upstream template; project-local augmentation (env vars, priming) stays in wrapper pre-step | session (v0.3 migration) |
| 2026-04-27 | `cleanroom-test` canonical location is `.agents/skills/cleanroom-test/` | Project-local skill, not from template; moved from `.claude/skills/` for consistency | session (v0.3 migration) |
| 2026-04-27 | Filed feedback: local augmentation mechanism for generic skills (GH issue #1) | No clean hook for project-local steps in template skills; proposed LOCAL.md overlay | session (v0.3 migration) |
| 2026-04-27 | Merge `plugins` + `comms-mgr` PM units into `handler-pipeline` | Tightly coupled, always loaded together; merged unit better reflects code boundary | pm-restructure |
| 2026-04-27 | Create `build-system` PM unit (extracted from `architecture` + `instrumentation`) | CMake config, install layout, and env vars were scattered; centralized for build-focused tasks | pm-restructure |
| 2026-07-29 | dh_comms host-pinned alloc uses `hipHostMallocUncached` (MTYPE_UC) rather than fixing `0x4`→`0x40000000` (recommended path, not yet applied) | Uncached host memory bypasses device L2, avoiding instrumentation-induced L2 pollution/misses; also fixes the latent `0x4` (=WriteCombined) typo from commit `0c8a3635` | L2 cache-miss investigation (`.untracked/`) |
| 2026-07-29 | Confirmed MI300X/CDNA3 L2 is shared per-XCD (per-XCC), not per-SE | ISA §9.1.10.2 has no shader-engine memory scope; per-SE recollection traced to sL1D/L1I (scalar+instruction L1) which *are* per-SE. Nabu cross-check agreed | L2 cache-miss investigation (`.untracked/`) |

# Current Focus

## Framework state (2026-08-25)

- **Upgraded to AMP v0.6** from v0.3, three versions in one run. The six workflow packets below
  were **suspended** first, not abandoned — `upgrade-project` refuses to migrate a repository with
  anything under `.agents/workflows/active/`, and all six had been dormant since April with
  blockers already needing human input. Contracts are intact; resume with
  `/workflow-resume <id>`. Two overlaps recorded in `active-workflows.md` still apply on resume.
- **This repository declares a plugin:** `plugins: ["../amd-agent-infra"]` in
  `.agents/project.json`. `session-init` resolves it read-only and reports one line in the
  briefing. **That names a private repository in this public one, and it was deliberate** — owner
  decision 2026-08-25, taken after measuring that the name appeared in zero commits of this repo's
  published history, so it is a first disclosure rather than an incremental one. It names no host,
  gateway, model, cluster, port or proxy. Recorded upstream as `[SEAM-Q5]` in
  `agentic_meta_project`'s `pm-decisions.md`. **Do not "fix" it by deleting the line** — the
  disclosure is in git history either way, and the declaration is what gives the framework's plugin
  seam a live consumer.
- **Local failure modes are `FM-L<n>`.** This repo's own `FM-4` collided with the framework's and
  is now `FM-L1`; content unchanged. Note `.agents/improvement/failure-modes.md` is a *preserved*
  file, so it never receives framework updates — its convention section is a dated snapshot and it
  carries none of the framework's FM-5..FM-13.

## Current Focus Areas

- Review and finalize Omniprobe whitepaper (ft_whitepaper-omniprobe — awaiting user review).
- Adopt lazy kernelDB loading in the interceptor (rf_lazy-kerneldb-loading — ready to start).
- Complete exact-architecture bitcode selection (rf_exact-arch-bitcode — ready to start).
- Purge logDuration naming from the codebase (rf_rename-logduration-to-omniprobe — needs open questions resolved).

## Active Workflows

- See `.agents/state/active-workflows.md` for all workflows.

## Immediate Next Recommended Actions

1. Execute rf_lazy-kerneldb-loading — upstream dependency resolved, 3-step change in interceptor.cc.
2. Execute rf_exact-arch-bitcode — upstream dependency resolved, rewrite getBitcodePath().
3. Resolve open questions for rf_rename-logduration-to-omniprobe (library name, env var prefix, backward compat).
4. Unblock rf_clang-format-consistency — coordinate with team for format commit.
5. Make design decisions for rf_test-organization.

## Project-Level Risks

- rocBLAS integration test broken (instrumented sscal not found in current build).

## Recent Decisions

- L2 cache miss investigation (2026-07-29): memory-system deep-dive continued. Confirmed MI300X L2 is per-XCD (not per-SE); documented `SC[1:0]` scope model + MTYPE bypass levers; found latent dh_comms `0x4` alloc-flag typo (benign); built + ran standalone host-pinned coherence test (`.untracked/coherence-test/`, all flags pass mid-kernel handshake on MI350X/gfx950). SQTT research completed (2026-07-28). See `.untracked/l2-cache-miss-investigation.md` and `.untracked/amd_gpu_memory_system.md`.
- Completed ft_omniprobe-python-api (2026-07-20): Python API at `omniprobe/api/`, structured JSON schemas for MemoryAnalysis and BasicBlockAnalysis. Enables IntelliKit integration.
- Completed rf_triton-v3.7-bump (2026-07-13): Triton bumped v3.6.0 → v3.7.1, all tests pass.
- PM restructured (2026-04-27): merged plugins+comms-mgr → handler-pipeline; created build-system unit.
- PM units re-verified against source code (2026-04-27); all 10 units current.

## Reading Path for the Next Session

1. `.agents/state/current-focus.md`
2. `.agents/state/active-workflows.md`
3. `.untracked/l2-cache-miss-investigation.md` — if continuing SQTT/L2 work
4. `.untracked/amd_gpu_memory_system.md` — memory hierarchy, scope/MTYPE model, Part 4 atomics/coherence placeholder

# Current Focus

## Current Focus Areas

- Bump Triton from v3.6.0 to v3.7.0 (rf_triton-v3.7-bump — active, ready to execute).
- Review and finalize Omniprobe whitepaper (ft_whitepaper-omniprobe — awaiting user review).
- Adopt lazy kernelDB loading in the interceptor (rf_lazy-kerneldb-loading — ready to start).
- Complete exact-architecture bitcode selection (rf_exact-arch-bitcode — ready to start).
- Purge logDuration naming from the codebase (rf_rename-logduration-to-omniprobe — needs open questions resolved).

## Active Workflows

- See `.agents/state/active-workflows.md` for all workflows.

## Immediate Next Recommended Actions

1. Execute rf_triton-v3.7-bump — CI staleness check failing, Triton v3.7.0 released 2026-05-07. Start with Step 1 (patch compatibility check).
2. Execute rf_lazy-kerneldb-loading — upstream dependency resolved, 3-step change in interceptor.cc.
3. Execute rf_exact-arch-bitcode — upstream dependency resolved, rewrite getBitcodePath().
4. Resolve open questions for rf_rename-logduration-to-omniprobe (library name, env var prefix, backward compat).
5. Unblock rf_clang-format-consistency — coordinate with team for format commit.
6. Make design decisions for rf_test-organization.

## Project-Level Risks

- Library filter chain test 2 hangs; rocBLAS integration test broken.
- Triton staleness check CI job failing (v3.6.0 pinned, v3.7.0 released).

## Recent Decisions

- Created rf_triton-v3.7-bump workflow (2026-06-01) to address Triton version drift.
- PM restructured (2026-04-27): merged plugins+comms-mgr → handler-pipeline; created build-system unit.
- PM units re-verified against source code (2026-04-27); all 10 units current.

## Reading Path for the Next Session

1. `.agents/state/current-focus.md`
2. `.agents/state/active-workflows.md`
3. `.agents/workflows/active/rf_triton-v3.7-bump/handoff.md` and `dossier.md`
4. `containers/triton_install.sh` lines 146-173 (patch function)
5. `src/instrumentation/` (LLVM pass source files)

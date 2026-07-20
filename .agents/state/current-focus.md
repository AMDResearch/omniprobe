# Current Focus

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

- Completed ft_omniprobe-python-api (2026-07-20): Python API at `omniprobe/api/`, structured JSON schemas for MemoryAnalysis and BasicBlockAnalysis. Enables IntelliKit integration.
- Completed rf_triton-v3.7-bump (2026-07-13): Triton bumped v3.6.0 → v3.7.1, all tests pass.
- PM restructured (2026-04-27): merged plugins+comms-mgr → handler-pipeline; created build-system unit.
- PM units re-verified against source code (2026-04-27); all 10 units current.

## Reading Path for the Next Session

1. `.agents/state/current-focus.md`
2. `.agents/state/active-workflows.md`

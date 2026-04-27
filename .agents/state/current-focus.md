# Current Focus

## Current Focus Areas

- Write Omniprobe whitepaper (ft_whitepaper-omniprobe — active, ready to execute).
- Adopt lazy kernelDB loading in the interceptor (rf_lazy-kerneldb-loading — ready to start).
- Complete exact-architecture bitcode selection (rf_exact-arch-bitcode — ready to start).
- Purge logDuration naming from the codebase (rf_rename-logduration-to-omniprobe — needs open questions resolved).

## Active Workflows

- See `.agents/state/active-workflows.md` for all workflows.

## Immediate Next Recommended Actions

1. Execute ft_whitepaper-omniprobe — packet active, plan of record has 10 steps, start with PM unit research.
2. Execute rf_lazy-kerneldb-loading — upstream dependency resolved, 3-step change in interceptor.cc.
3. Execute rf_exact-arch-bitcode — upstream dependency resolved, rewrite getBitcodePath().
4. Resolve open questions for rf_rename-logduration-to-omniprobe (library name, env var prefix, backward compat).
5. Unblock rf_clang-format-consistency — coordinate with team for format commit.
6. Make design decisions for rf_test-organization.

## Project-Level Risks

- Library filter chain test 2 hangs; rocBLAS integration test broken.

## Recent Decisions

- PM restructured (2026-04-27): merged plugins+comms-mgr → handler-pipeline; created build-system unit.
- PM units re-verified against source code (2026-04-27); all 10 units current.
- rocprofiler-sdk is now the tool registration mechanism (replaced HSA_TOOLS_LIB).
- instrument-amdgpu-kernels absorbed into src/instrumentation/ (no longer a submodule).

## Reading Path for the Next Session

1. `.agents/state/current-focus.md`
2. `.agents/state/active-workflows.md`
3. Relevant workflow's `handoff.md` and `dossier.md`
4. PM units from `.agents/pm/pm-index.md`

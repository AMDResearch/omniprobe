# Current Focus

## Current Focus Areas

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

- Library filter chain test 2 hangs; rocBLAS integration test broken.
- KT → PM migration just completed — PM units should be verified in first real session.

## Recent Decisions

- Migrated from KT system to v0.3 PM (2026-04-27).
- rocprofiler-sdk is now the tool registration mechanism (replaced HSA_TOOLS_LIB).
- instrument-amdgpu-kernels absorbed into src/instrumentation/ (no longer a submodule).

## Reading Path for the Next Session

1. `.agents/state/current-focus.md`
2. `.agents/state/active-workflows.md`
3. Relevant workflow's `handoff.md` and `dossier.md`
4. PM units from `.agents/pm/pm-index.md`

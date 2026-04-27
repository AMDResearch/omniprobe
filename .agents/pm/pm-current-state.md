# Project Current State

## Summary

Omniprobe is a GPU kernel instrumentation toolkit for HIP/Triton. The project is in active
development with a stable core (interceptor, handlers, instrumentation plugins) and ongoing
refactors to improve naming consistency, architecture cleanliness, and test organization.

## Active Work Areas

1. **Lazy kernelDB loading** — kerneldb PR #27 merged (2026-04-14). Ready to adopt
   `addFile(lazy=true)` in interceptor to replace `scanCodeObject()`. See rf_lazy-kerneldb-loading.
2. **Exact-architecture bitcode** — dh_comms PR #18 merged (2026-04-15). Plugin needs
   `getBitcodePath()` rewrite for exact-arch selection. See rf_exact-arch-bitcode.
3. **logDuration → omniprobe rename** — comprehensive rename of library, env vars, classes.
   Planned but not started. See rf_rename-logduration-to-omniprobe.
4. **clang-format consistency** — blocked on team coordination for initial format commit.
   See rf_clang-format-consistency.
5. **Test organization** — design decisions needed before restructuring tests/.
   See rf_test-organization.

## Current Risks

- **KT → PM migration committed**: The v0.3 migration is now committed (2026-04-27). PM
  units need verification; some content may need updating. Old KT dossiers archived in
  `.agents/kt.archive/`.
- **Library filter chain tests flaky**: Test 2 hangs; tests 4-5 previously failed.
- **rocBLAS integration test broken**: Instrumented sscal not found in current build.

## Changed Assumptions

- rocprofiler-sdk is now the tool registration mechanism (replaced HSA_TOOLS_LIB).
- instrument-amdgpu-kernels is absorbed into src/instrumentation/ (no longer a submodule).
- Standalone ROCm/rocBLAS and ROCm/hipBLASLt repos are deprecated; use rocm-libraries monorepo.
- `.claude/skills/` wrappers are thin delegates to `.agents/skills/` (canonical location).
  Project-local augmentation (env vars, permission priming) stays in the `.claude/` wrapper.
- `cleanroom-test` is a project-local skill (not from the agentic meta project template).

## Recommended Read Order

1. `architecture` — system overview and subsystem map
2. PM unit for the subsystem you're working on
3. Active workflow dossier for your current task

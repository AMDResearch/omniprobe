# Project Current State

## Summary

Omniprobe is a GPU kernel instrumentation toolkit for HIP/Triton. The project is in active
development with a stable core (interceptor, handlers, instrumentation plugins) and ongoing
refactors to improve naming consistency, architecture cleanliness, and test organization.

## Active Work Areas

1. **Triton v3.7.0 bump** — CI staleness check failing; Triton v3.7.0 released 2026-05-07,
   pinned version is v3.6.0. Workflow packet created (rf_triton-v3.7-bump), ready to execute.
   Key risks: LLVM API compatibility and source patch compatibility with v3.7.0.
2. **Lazy kernelDB loading** — kerneldb PR #27 merged (2026-04-14). Ready to adopt
   `addFile(lazy=true)` in interceptor to replace `scanCodeObject()`. See rf_lazy-kerneldb-loading.
3. **Exact-architecture bitcode** — dh_comms PR #18 merged (2026-04-15). Plugin needs
   `getBitcodePath()` rewrite for exact-arch selection. See rf_exact-arch-bitcode.
4. **logDuration → omniprobe rename** — comprehensive rename of library, env vars, classes.
   Planned but not started. See rf_rename-logduration-to-omniprobe.
5. **clang-format consistency** — blocked on team coordination for initial format commit.
   See rf_clang-format-consistency.
6. **Test organization** — design decisions needed before restructuring tests/.
   See rf_test-organization.

## Current Risks

- **Library filter chain tests flaky**: Test 2 hangs; tests 4-5 previously failed.
- **rocBLAS integration test broken**: Instrumented sscal not found in current build.

## Changed Assumptions

- rocprofiler-sdk is now the tool registration mechanism (replaced HSA_TOOLS_LIB).
- instrument-amdgpu-kernels is absorbed into src/instrumentation/ (no longer a submodule).
- Standalone ROCm/rocBLAS and ROCm/hipBLASLt repos are deprecated; use rocm-libraries monorepo.
- `.claude/skills/` wrappers are thin delegates to `.agents/skills/` (canonical location).
  Project-local augmentation (env vars, permission priming) stays in the `.claude/` wrapper.
- `cleanroom-test` is a project-local skill (not from the agentic meta project template).
- PM restructured (2026-04-27): `plugins` + `comms-mgr` merged into `handler-pipeline`;
  new `build-system` unit created from `architecture` + `instrumentation` extracts.

## Recommended Read Order

1. `architecture` — system overview and subsystem map
2. `build-system` — if working on CMake, build config, or environment setup
3. PM unit for the subsystem you're working on
4. Active workflow dossier for your current task

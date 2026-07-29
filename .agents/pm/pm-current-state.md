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

- **Library filter chain tests**: Previously flaky (test 2 hung, tests 4-5 failed). As of
  2026-07-13 all 5 tests pass.
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
- Triton pinned at v3.7.1 (bumped from v3.6.0, 2026-07-13). LLVM `PassPlugin.h` moved to
  `llvm/Plugins/PassPlugin.h`; instrumentation passes use `__has_include` for portability.
- JSON output restructured (2026-07-20, ft_omniprobe-python-api): MemoryAnalysis and
  BasicBlockAnalysis emit flat, machine-readable JSON schemas. Previous nested
  `kernel_analysis.cache_analysis` structure replaced. Python API at `omniprobe/api/`
  provides programmatic access via `Omniprobe.analyze_memory()` and
  `Omniprobe.analyze_basic_blocks()`.
- L2 cache-miss investigation (research, docs in `.untracked/`, 2026-07-29): MI300X L2 is
  per-XCD not per-SE; ISA `SC[1:0]` scope model governs all vector memory ops; MTYPE_UC
  (`hipHostMallocUncached` / `hipDeviceMallocUncached`) and system-scope both bypass device
  L2 — candidate mitigations for dh_comms L2 pollution. Found latent `0x4` alloc-flag typo in
  `dh_comms.cpp` (benign, see `sub-dh-comms` Known Issues). Standalone host-pinned coherence
  test at `.untracked/coherence-test/` (build to `/tmp`, run there — repo mount is FUSE, no
  mmap). Not yet a workflow; deep atomics/coherence chapter is a placeholder in
  `amd_gpu_memory_system.md`.

## Recommended Read Order

1. `architecture` — system overview and subsystem map
2. `build-system` — if working on CMake, build config, or environment setup
3. PM unit for the subsystem you're working on
4. Active workflow dossier for your current task

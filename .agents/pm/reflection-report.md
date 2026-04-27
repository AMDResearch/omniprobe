# PM Reflection Report

**Date:** 2026-04-27

## Coverage Gaps

- **Build system / CMake** — No PM unit covers the CMake build system (`CMakeLists.txt`,
  `cmake_modules/`, build configuration). Three workflows touch CMake files
  (rf_exact-arch-bitcode, rf_rename-logduration, rf_clang-format). Build knowledge is
  scattered across `architecture` (brief mention), `instrumentation` (build system section),
  and `testing` (test kernels CMake). A dedicated unit would centralize CMake patterns,
  install tree layout, and multi-LLVM-variant build logic.

- **CI / Containers** — No PM unit covers the container-based CI pipeline
  (`containers/`, `.github/workflows/`). The rf_rename-logduration workflow touches both.
  CI architecture (two-tier Apptainer images, toolchain vs omniprobe layers) is documented
  only in auto-memory, not PM.

## Split Candidates

- **`architecture`** — covers 5+ distinct topics: system diagram, subsystem map, environment
  variables, path layout (build + install tree), build instructions, and invariants. The
  environment variables and path layout sections are reference material that could be
  extracted into a dedicated `build-system` unit (see coverage gap above), leaving
  `architecture` focused on system design and data flow.

## Merge Candidates

- **`plugins` + `comms-mgr`** — These units are tightly coupled: `comms_mgr` is the only
  consumer of the plugin factory interface (it calls `getMessageHandlers()` during
  `checkoutCommsObject()`). Both are small (< 65 lines). A merged `handler-pipeline` unit
  covering handler loading → pool management → dispatch attachment would better match how
  agents actually work with this code.

## Potentially Obsolete Units

- No workflows have reached `done` state, so load-frequency analysis was **skipped**. All
  10 units are retained as active. Once workflows complete, re-run this analysis to identify
  units that no workflow ever needed.

## Transient Noise

- **`sub-kerneldb`** :: "Pending refactor `rf_lazy-kerneldb-loading`: plan to switch from
  `scanCodeObject()` to `addFile(lazy=true)` at startup + per-kernel
  `ensureKernelLoaded()`." — This describes a planned workflow, not durable project truth.
  Move to the workflow dossier.

- **`testing`** :: "Library filter chain test 2 hangs; tests 4-5 previously failed. rocBLAS
  integration needs investigation." — This describes current bugs, not architectural
  knowledge. Move to `pm-current-state.md` risks or a bug-tracking workflow.

- **`testing`** :: "Related Workflows: `rf_lazy-kerneldb-loading`" — Workflow cross-reference
  belongs in the workflow dossier, not PM.

- **`architecture`** :: "liblogDuration64.so" and all `LOGDUR_*` environment variable names —
  These will change when rf_rename-logduration executes. Not transient per se, but flagged as
  a staleness risk: the rename workflow will require updates to `architecture`,
  `omniprobe-cli`, `plugins`, `comms-mgr`, and `interceptor` units.

## Missing Negative Knowledge

- **`architecture`** — FM-2 (Excessive PM loading) is a project-wide pattern but no unit
  captures a reminder about minimal PM loading. Consider adding to `architecture` negative
  knowledge: "Do not front-load all PM units. Use `pm-load` for task-relevant selection."

- **`instrumentation`** — No negative knowledge about the bitcode two-bucket approach being
  incorrect (wave64/wave32 incompatibility for RDNA). This is the core motivation for
  rf_exact-arch-bitcode and should be captured once that refactor completes.

- **`testing`** — FM-3 (Premature workflow execution) isn't test-specific, but no unit
  captures the failure mode that test infrastructure changes require design decisions before
  execution (relevant to rf_test-organization being stalled).

## Staleness

- **`comms-mgr`** — Last Verified: 2026-03-03 (55 days ago). Should be re-verified against
  current source.
- **`plugins`** — Last Verified: 2026-03-02 (56 days ago). Should be re-verified.
- **`sub-dh-comms`** — Last Verified: 2026-03-02 (56 days ago). Should be re-verified.
- **`memory-analysis`** — Last Verified: 2026-03-03 (55 days ago). Should be re-verified.

## Recommendations

1. **Create `build-system` unit** — Extract CMake build configuration, install tree layout,
   multi-LLVM-variant logic, and environment variable reference from `architecture` and
   `instrumentation` into a new unit. This fills the biggest coverage gap.

2. **Consider merging `plugins` + `comms-mgr`** — These are small, tightly coupled, and
   always loaded together. A merged `handler-pipeline` unit would reduce unit count and
   better reflect the actual code boundary. Evaluate after re-verifying both units.

3. **Remove transient noise from `sub-kerneldb` and `testing`** — Move workflow references
   and current-bug descriptions to their proper homes (workflow dossiers,
   `pm-current-state.md`).

4. **Re-verify stale units** — `comms-mgr`, `plugins`, `sub-dh-comms`, and
   `memory-analysis` are all 55+ days old. Run a focused verification pass against current
   source before the next workflow execution.

5. **Plan PM updates for the rename refactor** — rf_rename-logduration will touch naming in
   at least 5 PM units. When that workflow executes, include a PM update pass as a
   verification step to prevent mass staleness.

6. **Defer CI/containers unit** — CI knowledge is useful but low-frequency. Capture it only
   if a CI-focused workflow is created. For now, auto-memory coverage is sufficient.

7. **Add negative knowledge post-refactor** — After rf_exact-arch-bitcode completes, add
   negative knowledge to `instrumentation` about the two-bucket bitcode approach being
   architecture-incorrect.

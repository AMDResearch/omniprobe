# Workflow Dossier: rf_exact-arch-bitcode

## Metadata

- Workflow ID: rf_exact-arch-bitcode
- Workflow Type: refactor
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Created: 2026-04-16 (migrated from KT); resumed 2026-11-08
- Base Commit: 003af80
- Dependencies: dh_comms PR #18 (merged 2026-04-15); PR #38 (lwitschen) folded in per D2
- Failure Policy: stop

```write-scope
src/instrumentation/InstrumentationCommon.cpp
tests/test_kernels/CMakeLists.txt
tests/test_bitcode_selection.sh
tests/run_all_tests.sh
tests/gfx950_runtime_validation.sh
external/dh_comms
.agents/workflows/active/rf_exact-arch-bitcode/
```

`external/dh_comms` is a submodule (AMDResearch/dh_comms). Changes there need the supervisor's
go-ahead: it is a separate repository (see handoff, "dh_comms has no gfx950").

## Objective

Replace the two-bucket (cdna2/cdna3) bitcode selection in the instrumentation plugins with
exact-architecture bitcode, falling back to the legacy bucket when the exact file is missing
(Rene, D2, 2026-11-08). Derive the architecture from the module triple when the module carries
no `target-cpu` (Triton since v3.9.0: `amdgpu9.0a-amd-amdhsa`).

## Spec changes on resumption (2026-11-08, under D2)

The April plan removed the legacy cdna2/cdna3 files and then the fallback (old steps 4-5, old
AC-4 "only exact-arch .bc files"). D2 keeps the fallback, so those steps and that criterion are
dropped. The PR #38 CMake hunk is superseded: `copy_bitcode` moved to the top-level
`CMakeLists.txt` (build-tree bitcode, 2026-11-08) and already copies every per-arch file dh_comms
builds.

## Non-Goals / Invariants

- No behavioural change for gfx90a / gfx94x users (the exact-arch file for those is compiled
  with the same `--offload-arch` as the legacy bucket).
- No API changes.
- Exact-arch bitcode is used only for architectures dh_comms identifies (its `gcnarch` enum).
  For any other architecture the device code reports `gcnarch::unsupported` and MemoryAnalysis
  silently skips cache-line analysis, so the legacy bucket is the safer choice.

## Acceptance Criteria

1. Build: `cmake --build build` succeeds (gfx90a).
2. Full suite `tests/run_all_tests.sh` passes on gfx90a.
3. gfx90a compile links `dh_comms_dev_gfx90a_co6.bc` (exact file). Fails before: `_cdna2_`.
4. Cross-compile for an architecture dh_comms supports but whose exact file is absent (gfx942,
   gfx908) links the legacy bucket (cdna3 / cdna2) and prints a warning naming the missing
   file. Fails before: no warning.
5. Cross-compile for gfx950 links the legacy bucket with a warning that dh_comms does not
   identify gfx950 (until dh_comms supports it; then the exact file).
6. A module with triple `amdgpu9.0a-amd-amdhsa` and no `target-cpu`, run through the -triton
   plugin, detects gfx90a and links the gfx90a bitcode. Fails before: "Could not determine
   target architecture, defaulting to cdna2".
7. `tests/gfx950_runtime_validation.sh` exists: self-contained, builds a gfx950 tree outside
   `build/`, runs the GPU suites that dispatch instrumented kernels. Runtime results on MI350
   are recorded when the supervisor moves the allocation.

## Rejected Approaches

- Keep two-bucket model and add RDNA buckets — scales poorly.
- Generate bitcode for all known architectures unconditionally — wasteful.
- PR #38 as submitted (any `gfxNNN` -> `_gfxNNN`, no file check): a missing per-arch file
  becomes a fatal compile error, and an architecture dh_comms does not know gets bitcode that
  reports `unsupported`.

## Open Questions

1. Does s_getreg_b32 hwreg(HW_REG_HW_ID) work on RDNA? (RDNA out of scope here.)
2. Should gcnarch enum be renamed to gpuarch? (Not here.)

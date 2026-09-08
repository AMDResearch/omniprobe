# Project Current State

## Summary

Omniprobe is a GPU kernel instrumentation toolkit for HIP/Triton. The project is in active
development with a stable core (interceptor, handlers, instrumentation plugins) and ongoing
refactors to improve naming consistency, architecture cleanliness, and test organization.

## Active Work Areas

No workflow is active. All six remaining packets are suspended; the seventh,
`bf_hip-duplicate-code-object-load`, completed 2026-09-08.

1. **Lazy kernelDB loading** — kerneldb PR #27 merged (2026-04-14). **Its premise is partly
   invalidated**: the packet declares "No changes to coCache" and plans to delete
   `src/interceptor.cc:802-808`, both written in April and both now false of this tree. That block
   is no longer load-bearing for the old `-k` workaround, but it still is for DWARF correlation.
   Revisit the contract before executing. See rf_lazy-kerneldb-loading.
2. **Exact-architecture bitcode** — dh_comms PR #18 merged (2026-04-15). Plugin needs
   `getBitcodePath()` rewrite for exact-arch selection. See rf_exact-arch-bitcode.
3. **logDuration → omniprobe rename** — comprehensive rename of library, env vars, classes.
   Planned but not started. See rf_rename-logduration-to-omniprobe.
4. **clang-format consistency** — blocked on team coordination for initial format commit.
   See rf_clang-format-consistency.
5. **Test organization** — design decisions needed before restructuring tests/.
   See rf_test-organization.

## Active Work Areas — three bugfix packets (2026-09-08)

All promoted the same day, none with production code written. Ordered by the owner: the two filed
from the **IntelliKit sidecar** come first, because that project is blocked on both.

1. `bf_exit-status-not-propagated` — `omniprobe` always exits 0. **Needs no GPU** (`/bin/sh`
   stubs), so it is the cheapest of the three to pick up.
2. `bf_pyhandler-gil` — `pythonMessageHandler` has no GIL and is unreachable. Needs a GPU and an
   architecture-matched build. Ships as a plugin, not a core change.
3. `bf_intern-clone-name` — internal-linkage kernels under `-fgpu-rdc` fail instrumented-alternative
   lookup ~37.5% of the time, decided by one character of a content hash.

Each begins by re-stamping its own `Base Commit`: promoting three packets in one commit leaves
every gate reporting its siblings' directories as out-of-scope writes.

## Current Risks

- **Library filter chain tests**: Previously flaky (test 2 hung, tests 4-5 failed). As of
  2026-07-13 all 5 tests pass.
- ~~**rocBLAS integration test broken**: Instrumented sscal not found in current build.~~
  **RETRACTED 2026-09-08.** It is not broken. Measured on gfx90a hardware, it passes at
  `74c6ed2` and at HEAD — `Found instrumented alternative for sscal kernel`. The risk was
  recorded from a node where the suite could not run at all.
- **Unfiled defect: `.intern.<hash>` clone names.** A `static` (internal-linkage) `__global__`
  kernel under `-fgpu-rdc` gets a `.intern.<hash>` suffix that `getInstrumentedName`
  (`src/utils.cc:117`) does not reconstruct, so the kernel runs uninstrumented and prints
  `No instrumented alternative found`. Silent partial data loss. Correlation measured on PENNANT
  (`static` kernels fail, the one non-`static` kernel does not); the `-fgpu-rdc`-plus-internal-
  linkage mechanism is inferred, not tested. See `current-focus.md` for the proposed
  20-line reproducer and the one-command check that would confirm or kill the hypothesis.

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

- HIP duplicate code-object load fixed (2026-09-08, bf_hip-duplicate-code-object-load): for
  code the application loads itself, `coCache::addFile` now *indexes* the extracted code objects
  and builds **no private HSA executable**. The private copy's `__constant__` segment was never
  initialised, so instrumented clones read `__device__`/`__constant__` globals as zero while
  kernel arguments arrived intact — a silent failure producing empty-but-plausible analysis.
  Triton and `--library-filter` includes still get the private executable, since their
  instrumented kernels exist nowhere else. `-k` now gates the clone swap at dispatch instead of
  gating what gets recorded, so it means what it has always been documented to mean, and it no
  longer costs source-line attribution. PENNANT `sedovsmall` now runs under `omniprobe -i` with
  **no filter** and matches uninstrumented energies exactly; the `-k "setBoundary"`
  sacrificial-kernel workaround is obsolete.
- **Test kernels must be compiled for the GPU actually present, not for
  `CMAKE_HIP_ARCHITECTURES`.** Measured 2026-09-08: the gfx90a `build/` tree's test kernels
  dispatch **nothing** on a gfx950 node — silently, exit 0, no reports. This is the true cause of
  the long-standing "Handler tests fail on `memory heatmap report`" result on gfx950 nodes; the
  same source recompiled for gfx950 passes. It is an architecture mismatch, not a code defect.
  New tests (`tests/test_instrumented_kernel_common.sh`) detect the arch via `rocminfo` and
  compile to `/tmp`, which is also the mmap-capable filesystem on fuseblk/virtiofs nodes.
- Test environment variables are recorded in `.untracked/test-env.sh` (gitignored; this repo is
  public). `TRITON_DIR` is architecture-independent and travels between nodes;
  `INSTRUMENTED_ROCBLAS_LIB_DIR` and `INSTRUMENTED_HIPBLASLT_LIB_DIR` point at **gfx90a-only**
  Tensile libraries and fail with "not ISA compatible with this GPU" elsewhere, so the script
  exports them only when the detected arch matches.
- **The test suite is green, and it takes matching hardware to see that.** On gfx90a with
  `test-env.sh` sourced: 10 suites run, 10 passed, 0 skipped, 0 failed at HEAD, and 6/6 at
  `74c6ed2`. The previously recorded "1 passed / 4 skipped / 1 failed" was measured where four
  suites could not run and the fifth ran the wrong architecture's binaries. Two entries above and
  in `units/testing.md` were retracted on that evidence. The general form is worth keeping: **a
  tally measured where most suites skip records the environment, not the code.**

## Recommended Read Order

1. `architecture` — system overview and subsystem map
2. `build-system` — if working on CMake, build config, or environment setup
3. PM unit for the subsystem you're working on
4. Active workflow dossier for your current task

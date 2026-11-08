# Project Current State

## Summary

Omniprobe is a GPU kernel instrumentation toolkit for HIP/Triton. The project is in active
development with a stable core (interceptor, handlers, instrumentation plugins) and ongoing
refactors to improve naming consistency, architecture cleanliness, and test organization.

## Active Work Areas (2026-11-08, end of third session)

**No packet is active; the supervisor's 2026-11-08 queue is done.** This session completed
`rf_exact-arch-bitcode` with PR #38 (merged, lwitschen credited): exact-arch device bitcode with a
legacy fallback, the arch read from Triton's triple, gfx950 supported end to end (dh_comms
`9551a41` pushed), and the LDS bank-conflict model measured per architecture on gfx90a and gfx950
(`memory-analysis`). Also: 16-byte LDS writes miscounted (fixed), clean-parallel-build ordering
(fixed), `-d random` silent emptiness (now warned). Full suite: **27 suites** (`testing`).

**Final main `113d53b` verified on gfx90a (2026-11-08, fourth session):** 27/27 suites +
module-load 3/3 from a fresh clone; suites 3-5 needed their gitignored driver binaries rebuilt
(`testing`). Making those binaries a build target would let a fresh checkout pass unaided (not queued).

**Known follow-ups, not packets:** 1-/2-byte LDS phases on gfx950 unmeasured; `-d random` sampling semantics (Rene, deferred); PythonHandler interpreter teardown ownership (interpreter is
deliberately never finalized); PythonHandler inside a Python host (Triton) untested — possible
GIL deadlock at completion; a `--python-handler` launcher flag; docs name `OMNIPROBE_*`
environment variables where the code reads `LOGDUR_*` (noted on the suspended
`rf_rename-logduration-to-omniprobe`).

**Done 2026-11-08, first session:** `bf_intern-clone-name`,
`bf_library-filter-chain-silent-pass`, `bf_json-output-integrity`, `bf_bba-hardening`,
`bf_lds-split-entries`, `bf_logger-record-interleave`, `bf_plugin-dhcomms-cuid-duplicate`,
`bf_plugin-missing-bitcode-fatal`, `bf_source-attribution-gaps`, `bf_zero-param-kernel-match`, and the feature `ft_python-api-coverage`.
Leak scan gates pushes (`build-system`).

**GitHub (2026-11-08):** PRs #40 and #37 merged with authorship intact, plus follow-up commits;
PR #39 and issue #20 closed with comments; PR #42 untouched (deferred).

## Active Work Areas (superseded 2026-11-08 — kept for history)

Two bugfix packets are active (see the next section). The six packets listed below are
**suspended**, not active — four of them need human input before they can move.

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

## Active Work Areas — two bugfix packets (was three; updated 2026-10-26; superseded 2026-11-08)

Promoted 2026-09-08, neither with production code written. Ordered by the owner: the packets
filed from the **IntelliKit sidecar** come first, because that project is blocked on them.

1. `bf_pyhandler-gil` — `pythonMessageHandler` has no GIL and is unreachable. Needs a GPU and an
   architecture-matched build. Ships as a plugin, not a core change. **Now the only packet
   blocking IntelliKit**, so it is the top recommended action. Its AC-4 can drop the workaround
   it carried for the exit-status bug (it checked the target's own status because omniprobe's was
   useless); the packet text is deliberately unamended, since that write belongs to the packet.
2. `bf_intern-clone-name` — internal-linkage kernels under `-fgpu-rdc` fail instrumented-alternative
   lookup ~37.5% of the time, decided by one character of a content hash. **Its dossier's line
   references into `InstrumentationCommon.cpp` (e.g. `:211`) are stale**: `e6db747` and `b12d7f0`
   both edited that file after its Base Commit `5b9425f`. Re-find them, do not trust them.

Each begins by re-stamping its own `Base Commit`: promoting three packets in one commit leaves
every gate reporting its siblings' directories as out-of-scope writes.

**Draft (2026-10-27; done 2026-11-08): `bf_library-filter-chain-silent-pass`.** `tests/library_filter_chain/run_test.sh`
can report PASSED having run none of Tests 2–5, or having instrumented with a different tree's
plugin than the omniprobe under test. Diagnosed and reproduced by its `acceptance.sh`; not fixed.

**Completed 2026-10-26: `bf_exit-status-not-propagated`.** Packet in
`.agents/workflows/done/`. `omniprobe` propagates the child's exit status (`128 + signal` for
signal deaths, JSON finalized before exit). GitHub issue #41 closed. It had been code-complete
since 2026-09-08 and blocked solely on AC-8's `Suites skipped: 0`, which is unreachable off
gfx90a — met with no code change once a gfx90a node was available.

## Done 2026-10-26/27, without a packet

- **Triton bumped v3.7.1 → v3.8.0** (`7f18d4b`), after a local GPU validation and with the LLVM
  pin made verifiable (`e18e4bb`) and the toolchain image checkpointed (`913ae31`). Toolchain
  image and `build.yml` both green against it. See `build-system`.
- **Issue #43 closed; PR #44 merged** (`b12d7f0`, Lixun Zhang). Item 1 of #43 — the triple match —
  fixed first in `e6db747`; item 2 (the assert patch) was already handled. See `instrumentation`.

## Deliberately not a packet (2026-10-27)

- **Upstream Triton report** about `scripts/build-llvm-project.sh` (no `set -e`, and `jq -r`
  turning a missing key into `null` with exit 0). **Reported 2026-10-27** as a comment on
  triton-lang/triton#12413 (an existing `set -e` request whose PR #12415 was closed unmerged
  without comment), scoped by the owner to the jq-missing case: wrong LLVM commit built, exit 0.
  Asks ThomasRaoux why #12415 was closed and offers a PR (`set -e` + jq in the README). Wait for
  a reply; do not open the PR unprompted. Our own jq prerequisite stays (`pm-decisions`).
- **Fork-PR CI and the stale external PRs** (#20, #37–#40, #42): diagnosis in `build-system`.
  Needs owner decisions (approval policy, public toolchain image) before it can be a packet.
  #39 may be obsolete since `bf_hip-duplicate-code-object-load`; #38 overlaps
  `rf_exact-arch-bitcode`.
- **Log which `libLLVMCore` a plugin actually bound to** (from `/proc/self/maps`) — would turn the
  soname-collision hazard loud. An idea, not a commitment.

## Current Risks

- ~~**Library filter chain tests can pass without testing anything**~~ **FIXED 2026-11-08** — the suite now uses `OMNIPROBE_ROOT`'s plugin and fails on missing pieces. (Found 2026-10-27.) Its green
  is trustworthy only when run from a repo whose `build/` is the tree under test — then all 5
  tests do run and pass. See `bf_library-filter-chain-silent-pass` and `testing`.
- ~~**rocBLAS integration test broken**: Instrumented sscal not found in current build.~~
  **RETRACTED 2026-09-08.** It is not broken. Measured on gfx90a hardware, it passes at
  `74c6ed2` and at HEAD — `Found instrumented alternative for sscal kernel`. The risk was
  recorded from a node where the suite could not run at all.
- ~~**Unfiled defect: `.intern.<hash>` clone names.**~~ **FILED 2026-09-08 as
  `bf_intern-clone-name`; FIXED 2026-11-08** (`3e31ee8`, `8a3ea17`; see `interceptor`). The mechanism is no longer inferred: internal linkage *plus*
  `-fgpu-rdc` is necessary and sufficient, measured with a three-kernel in-repo probe. The defect
  is **intermittent at ~37.5% per translation unit**, decided by whether the content hash begins
  with a hex letter, because two independent defects cancel in the other ~62.5%. Read the
  packet's `dossier.md` § Background before touching `src/utils.cc` or
  `src/instrumentation/InstrumentationCommon.cpp`.
- ~~**The AMDGPU attributor's conclusions leak onto instrumented clones.**~~ **FIXED 2026-10-27**
  by PR #44 (`b12d7f0`): clones now get `workgroup_id_y/z` enabled. It affected the HIP path
  (2-D/3-D launches could collapse dh_comms sub-buffer indices); on Triton v3.8.0 it was latent,
  and #44 becomes live there when triton-lang/triton#10849 lands. See `instrumentation`.
- ~~**The next Triton bump is not a repeat of this one.**~~ **RESOLVED 2026-11-08** by the v3.9.0
  bump: #10849 and #11532 both landed with instrumented output unchanged (method in
  `build-system`). The general rule stands: validate a bump on a GPU node, with the test
  environment's Triton matched to the pin.
- **`-t json` without `-o` can collide**: two runs started in the same second share
  `results_<YYYY-mm-dd_HHMMSS>.json` in the cwd. Known, unfixed (`handler-pipeline`).
- **dh_comms and kerneldb are submodules this project cannot push to.** Fixes that would belong
  there (flat-address classification, kernelDB's `ROCM_PATH` default) were made on the omniprobe
  side instead (`pm-decisions`). Revisit if submodule write access changes.
- **CI cannot catch semantic breakage.** `build.yml` is build-only, `ubuntu-latest`, no GPU, no
  test invocation. A green CI run says the code compiles and nothing more. See `build-system`.

## Changed Assumptions

- rocprofiler-sdk is now the tool registration mechanism (replaced HSA_TOOLS_LIB).
- instrument-amdgpu-kernels is absorbed into src/instrumentation/ (no longer a submodule).
- Standalone ROCm/rocBLAS and ROCm/hipBLASLt repos are deprecated; use rocm-libraries monorepo.
- `.claude/skills/` wrappers are thin delegates to `.agents/skills/` (canonical location).
  Project-local augmentation (env vars, permission priming) stays in the `.claude/` wrapper.
- `cleanroom-test` is a project-local skill (not from the agentic meta project template).
- PM restructured (2026-04-27): `plugins` + `comms-mgr` merged into `handler-pipeline`;
  new `build-system` unit created from `architecture` + `instrumentation` extracts.
- Triton pinned at **v3.9.0** (bumped 2026-11-08, `ecb9a4c`; LLVM `b010a18d` = LLVM 24; see
  `build-system`). Previously v3.8.0 (2026-10-26, `7f18d4b`), v3.7.1 (2026-07-13).
  jq is now a build prerequisite. LLVM `PassPlugin.h` lives at `llvm/Plugins/PassPlugin.h` in
  Triton's fork; instrumentation passes use `__has_include` for portability.
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

- BasicBlockAnalysis no longer reports timing (2026-11-08): counts only, keyed by IR block
  ordinal, which does not match kernelDB's ISA blocks. Earlier timing-percentile schema
  statements are superseded (`handler-pipeline`, `omniprobe-cli`).
- Handler console reports go to stdout, interceptor messages to stderr (`2f60d83`).
- Configuration errors are fatal (2026-11-08): an unusable handler plugin, unknown analyzer or
  unusable PythonHandler module exits 1 with `omniprobe: ERROR`; no silent fallback to the
  default handlers. A dispatch is never dropped: kernelDB or instrumentation failures run it
  without attribution or uninstrumented, with an error (`interceptor`, `handler-pipeline`).
- Flat-pointer accesses are classified at run time (2026-11-08); `unanalyzed_flat_accesses`
  now means mixed-space waves only (`instrumentation`, `memory-analysis`).

## Recommended Read Order

1. `architecture` — system overview and subsystem map
2. `build-system` — if working on CMake, build config, or environment setup
3. PM unit for the subsystem you're working on
4. Active workflow dossier for your current task

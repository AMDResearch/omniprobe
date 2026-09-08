# Current Focus

## Defect found 2026-09-01, filed and FIXED 2026-09-08 — read before resuming any interceptor work

**`bf_hip-duplicate-code-object-load` — FIXED 2026-09-08, implementation complete, one criterion
outstanding.** Base commit `74c6ed2`. The whole plan of record (steps 1-10) is done; the gate reads
8 passed / 1 weak / 1 failed. **Only AC-4 remains, and it needs a gfx90a/MI210 node** — three
suites skip here because the instrumented rocBLAS/hipBLASLt libraries are gfx90a-only and this is
a gfx950 machine. Resume with `/workflow-resume bf_hip-duplicate-code-object-load` there; the
handoff carries a step-by-step plan. It is still the only active workflow and still holds
`src/interceptor.cc`, so the collision below stays live. The defect was: for a HIP fat binary, Omniprobe loads a second,
private copy of every code object the process already has mapped, and instrumented clones
dispatched out of it read `__device__`/`__constant__` globals as **zero**. The run completes and
produces empty-but-plausible analysis output — it fails silently. Found 2026-09-01 while
profiling PENNANT on MI350X; mechanism pinned to `coCache::addFile` (`src/utils.cc:503`) versus
`registerRuntimeKernel` (`src/utils.cc:206`) racing to write `lookup_map_`, first writer winning,
and startup beating first dispatch.

**This changes the standing recommendation below.** `rf_lazy-kerneldb-loading` was listed as the
next action to execute; it plans to delete `src/interceptor.cc:802–808`, the exact block that
primes the kernelDB and that the only known workaround for this defect depends on, and it
declares "No changes to coCache" as an invariant. Both assumptions were written in April, before
this was known. **Do not execute it without first reading**
`.agents/workflows/active/bf_hip-duplicate-code-object-load/dossier.md`.

Also worth knowing before running any acceptance gate in this repository: see Project-Level
Risks below on `.gitignore`.

## Verified this session (2026-09-08)

- **PENNANT `sedovsmall` runs correctly under `omniprobe -i` with no `-k` filter**, energies
  identical to an uninstrumented run (2.467991e-01 -> 2.467954e-01). The `-k "setBoundary"`
  sacrificial-kernel workaround is obsolete. Private code-object loads across PENNANT's 95
  objects: 0.
- **The "Handler tests fail on 'memory heatmap report'" result is an architecture artefact, not
  a defect.** `build/` is gfx90a and its test kernels silently fail to dispatch on this gfx950
  node — exit 0, no reports. The same source recompiled for gfx950 passes. This corrects a
  project-level risk that has been carried as a code defect.
- The `.intern.<hash>` clone-name defect (write-up section 3.2) now has a concrete reproducer:
  PENNANT `gpuMain3`/`gpuMain4`/`gpuMain5` at `cstop 1` print `No instrumented alternative
  found`. **Not yet filed as a packet.** Out of scope for the bugfix above by its own non-goals.

## Framework state (2026-08-25)

- **Upgraded to AMP v0.6** from v0.3, three versions in one run. The six workflow packets below
  were **suspended** first, not abandoned — `upgrade-project` refuses to migrate a repository with
  anything under `.agents/workflows/active/`, and all six had been dormant since April with
  blockers already needing human input. Contracts are intact; resume with
  `/workflow-resume <id>`. Two overlaps recorded in `active-workflows.md` still apply on resume.
- **This repository declares a plugin:** `plugins: ["../amd-agent-infra"]` in
  `.agents/project.json`. `session-init` resolves it read-only and reports one line in the
  briefing. **That names a private repository in this public one, and it was deliberate** — owner
  decision 2026-08-25, taken after measuring that the name appeared in zero commits of this repo's
  published history, so it is a first disclosure rather than an incremental one. It names no host,
  gateway, model, cluster, port or proxy. Recorded upstream as `[SEAM-Q5]` in
  `agentic_meta_project`'s `pm-decisions.md`. **Do not "fix" it by deleting the line** — the
  disclosure is in git history either way, and the declaration is what gives the framework's plugin
  seam a live consumer.
- **Local failure modes are `FM-L<n>`.** This repo's own `FM-4` collided with the framework's and
  is now `FM-L1`; content unchanged. Note `.agents/improvement/failure-modes.md` is a *preserved*
  file, so it never receives framework updates — its convention section is a dated snapshot and it
  carries none of the framework's FM-5..FM-13.

## Current Focus Areas

- Review and finalize Omniprobe whitepaper (ft_whitepaper-omniprobe — awaiting user review).
- Adopt lazy kernelDB loading in the interceptor (rf_lazy-kerneldb-loading — **no longer "ready
  to start"**; its premise is partly invalidated by `bf_hip-duplicate-code-object-load`, see top
  of this file).
- Fix the HIP duplicate-code-object load that zeroes `__constant__` memory
  (bf_hip-duplicate-code-object-load — **implementation complete**; only AC-4 outstanding, and it
  needs a gfx90a/MI210 node).
- Complete exact-architecture bitcode selection (rf_exact-arch-bitcode — ready to start).
- Purge logDuration naming from the codebase (rf_rename-logduration-to-omniprobe — needs open questions resolved).

## Active Workflows

- See `.agents/state/active-workflows.md` for all workflows.

## Immediate Next Recommended Actions

1. **Close out `bf_hip-duplicate-code-object-load` on a gfx90a/MI210 node.** Everything else is
   done. `/workflow-resume bf_hip-duplicate-code-object-load` there, `source
   .untracked/test-env.sh` (it exports the instrumented-library variables only when the arch
   matches), use the `build/` tree, re-record the stale `baseline-run_all_tests.txt`, then run the
   gate. The handoff has the full step-by-step, including the one judgement call it may need from
   you: AC-4's implemented check demands `Suites failed: 0` while its text only demands no
   regression against the baseline, and aligning them would be a loosening requiring approval.
2. **Was: execute rf_lazy-kerneldb-loading.** Superseded as a next action on 2026-09-08 — read
   `bf_hip-duplicate-code-object-load`'s dossier first and sequence the two deliberately. Its
   plan step 4 removes the block the other packet's workaround depends on.
3. Execute rf_exact-arch-bitcode — upstream dependency resolved, rewrite getBitcodePath(). Note
   the PENNANT session also found `gfx950` maps to the CDNA2 bitcode
   (`src/instrumentation/InstrumentationCommon.cpp:109`) and that `gcnarch`
   (`external/dh_comms/include/message.h:44`) has no `gfx950` entry at all — the analysis
   currently produces correct numbers only because the CDNA2 header's hardcoded 128-byte cache
   line happens to be right for MI350X. That is luck, not design, and it is adjacent to this
   packet's scope.
3. Resolve open questions for rf_rename-logduration-to-omniprobe (library name, env var prefix, backward compat).
4. Unblock rf_clang-format-consistency — coordinate with team for format commit.
5. Make design decisions for rf_test-organization.

## Project-Level Risks

- **rocBLAS integration test broken (instrumented sscal not found in current build).** Now
  directly relevant: this is the main thing that could still block AC-4 on a gfx90a node, where
  the three rocBLAS/hipBLASLt suites will *run* rather than skip. Making them run is not the same
  as making them pass.
- ~~`.gitignore` does not ignore sibling build trees, so every acceptance gate reports a useless
  74 KB scope failure.~~ **FIXED 2026-09-08 in `fe66ff4`** by adding `build*/`. Kept here as a
  record of what it cost: while it stood, a real out-of-scope write would have been invisible in
  that output, and in fact two genuine ones (`inc/interceptor.h`, `.gitignore` itself) were only
  spotted once the noise was gone. *An earlier version of this entry said `.gitignore` "contains
  `build` only"; it never did — the bare pattern `build` simply does not match `build_gfx950`.*
- **Test-environment variables are set, and one of them does not travel between nodes.**
  `TRITON_DIR` is architecture-independent — verified 2026-09-08, the
  Triton suite passes on gfx950 with a tree built on gfx90a. It is now in
  `.claude/settings.local.json`'s `env` block. `INSTRUMENTED_ROCBLAS_LIB_DIR` and
  `INSTRUMENTED_HIPBLASLT_LIB_DIR` are **gfx90a-only** and fail with `not ISA compatible with
  this GPU` on this gfx950 node, so they are exported conditionally by
  `.untracked/test-env.sh` (`source` it) and stay unset here. Suite tally on gfx950: unset →
  1 passed / 4 skipped / 1 failed; all set → 2 passed / 0 skipped / 4 failed. **The values live
  only in `.untracked/test-env.sh` and `.claude/settings.local.json`, both gitignored** — they
  are personal absolute paths and this repository is public. Do not copy them into a tracked
  file; refer to the variable names instead.
- **The test suite is not green and mostly does not run.** Measured 2026-09-08 at `74c6ed2`:
  `tests/run_all_tests.sh` → 6 suites run, 1 passed, **4 skipped** for unset environment
  variables (`TRITON_DIR`, `INSTRUMENTED_ROCBLAS_LIB_DIR`, …), **1 failed** — Handler tests, on
  `Expected pattern not found: 'memory heatmap report'`. Note `tests/triton/run_test.sh` **exits
  0 when it skips**, so any check reading only its exit status records a pass for a suite that
  never ran. Baseline recorded in
  `.agents/workflows/active/bf_hip-duplicate-code-object-load/baseline-run_all_tests.txt`.
  A fourth quirk found 2026-09-08, **latent rather than active**: `tests/run_all_tests.sh:59`
  classifies a whole suite as skipped if the string `SKIP` appears anywhere in its output, and
  `tests/rocblas_hipblaslt/run_test.sh:220` emits one mid-run — so a suite that ran can be
  tallied as skipped. Measured with the environment variables set: it did **not** fire, because
  the Tensile search at `run_test.sh:86` matches on filename glob plus a `__amd_crk_Cijk` symbol
  check, not on architecture, so it finds the gfx90a hsaco even on a gfx950 node. It would fire
  on a build without instrumented Tensile kernels. Worth knowing because any criterion demanding
  `Suites skipped: 0` inherits this classifier.

## Recent Decisions

- L2 cache miss investigation (2026-07-29): memory-system deep-dive continued. Confirmed MI300X L2 is per-XCD (not per-SE); documented `SC[1:0]` scope model + MTYPE bypass levers; found latent dh_comms `0x4` alloc-flag typo (benign); built + ran standalone host-pinned coherence test (`.untracked/coherence-test/`, all flags pass mid-kernel handshake on MI350X/gfx950). SQTT research completed (2026-07-28). See `.untracked/l2-cache-miss-investigation.md` and `.untracked/amd_gpu_memory_system.md`.
- Completed ft_omniprobe-python-api (2026-07-20): Python API at `omniprobe/api/`, structured JSON schemas for MemoryAnalysis and BasicBlockAnalysis. Enables IntelliKit integration.
- Completed rf_triton-v3.7-bump (2026-07-13): Triton bumped v3.6.0 → v3.7.1, all tests pass.
- PM restructured (2026-04-27): merged plugins+comms-mgr → handler-pipeline; created build-system unit.
- PM units re-verified against source code (2026-04-27); all 10 units current.

## Reading Path for the Next Session

1. `.agents/state/current-focus.md`
2. `.agents/state/active-workflows.md`
2a. `.agents/workflows/active/bf_hip-duplicate-code-object-load/handoff.md` then `dossier.md` —
    if touching
    `src/interceptor.cc`, `src/utils.cc`, or any kernel-discovery / code-object-loading path
3. `.untracked/l2-cache-miss-investigation.md` — if continuing SQTT/L2 work
4. `.untracked/amd_gpu_memory_system.md` — memory hierarchy, scope/MTYPE model, Part 4 atomics/coherence placeholder

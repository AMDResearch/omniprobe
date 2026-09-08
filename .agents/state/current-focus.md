# Current Focus

## Read this before touching kernel discovery or code-object loading

**The HIP duplicate-code-object-load defect is FIXED** (`bf_hip-duplicate-code-object-load`,
completed 2026-09-08, packet in `.agents/workflows/done/`). The defect was: for a HIP fat binary,
Omniprobe loaded a second, private copy of every code object the process already had mapped, and
instrumented clones dispatched out of it read `__device__`/`__constant__` globals as **zero** —
silently, producing empty-but-plausible analysis output.

What the tree now does, and what depends on it:

- Application-loaded code objects are **indexed**, not loaded into a private HSA executable.
  `coCache::addFile` still builds one for `--library-filter` includes and for Triton, which
  genuinely need it. The log line distinguishes them: `Indexing` versus `Adding`.
- `-k <regex>` now means what the documentation always said — it gates the *clone swap at
  dispatch*, not which copy a clone comes from.
- `kernel_co_map_` is populated regardless of the filter, so a filtered run keeps DWARF
  source-line attribution. **The sacrificial-kernel workaround (`-k "setBoundary"`) is obsolete.**

**`rf_lazy-kerneldb-loading` must not be resumed against its own premise.** Its plan step 4
deletes `src/interceptor.cc:802-808` and its invariants declare "No changes to coCache" — now
straightforwardly false of this tree. That block is no longer load-bearing for the old workaround,
but it *is* still load-bearing for DWARF correlation. Revisit the contract before execution, not
during. See `.agents/state/active-workflows.md`.

## Corrected 2026-09-08 — two long-standing "known defects" that do not exist

Both were artefacts of running gfx90a binaries on a gfx950 GPU, where they fail to dispatch
silently and produce exit 0 with no output. Measured on `k005-005.hpcfund` (MI210 / gfx90a):

- **The Handler-tests failure** (`Expected pattern not found: 'memory heatmap report'`) was
  carried in this file and in the bugfix packet as a pre-existing code defect for months. It is
  not one. The suite passes on matching hardware, at the base commit and at HEAD.
- **"rocBLAS integration test broken — instrumented `sscal` not found in current build"** was
  recorded as a project-level risk and named as the one thing that could block the bugfix's AC-4.
  It passes at `74c6ed2` and at HEAD. `Found instrumented alternative for sscal kernel`.

**The test suite is green.** With `.untracked/test-env.sh` sourced on a gfx90a node:
10 suites run, 10 passed, 0 skipped, 0 failed at HEAD; 6/6 at `74c6ed2`. The general lesson is
worth more than either correction: **a suite tally measured where most suites skip records the
environment, not the code** — and a binary built for the wrong architecture does not error, it
quietly does nothing.

## Current Focus Areas

- Review and finalize Omniprobe whitepaper (ft_whitepaper-omniprobe — awaiting user review).
- Adopt lazy kernelDB loading in the interceptor (rf_lazy-kerneldb-loading — **contract needs
  revisiting first**, see above).
- Complete exact-architecture bitcode selection (rf_exact-arch-bitcode — ready to start).
- Purge logDuration naming from the codebase (rf_rename-logduration-to-omniprobe — needs open
  questions resolved).

## Active Workflows

None. See `.agents/state/active-workflows.md` — six suspended, none active.

## Immediate Next Recommended Actions

1. **File a packet for the `.intern.<hash>` clone-name defect.** Still unfiled, and it now has a
   concrete reproducer: PENNANT `gpuMain3`/`gpuMain4`/`gpuMain5` at `cstop 1` print `No
   instrumented alternative found`. The mechanism is `.intern.<hash>` suffixing breaking clone-name
   reconstruction in `getInstrumentedName` (`src/utils.cc:117`). It was an explicit non-goal of
   the completed bugfix.
2. Execute `rf_exact-arch-bitcode` — upstream dependency resolved, rewrite `getBitcodePath()`.
   Note `gfx950` maps to the CDNA2 bitcode (`src/instrumentation/InstrumentationCommon.cpp:109`)
   and `gcnarch` (`external/dh_comms/include/message.h:44`) has no `gfx950` entry at all — the
   analysis currently produces correct numbers only because the CDNA2 header's hardcoded 128-byte
   cache line happens to be right for MI350X. That is luck, not design.
3. Revisit `rf_lazy-kerneldb-loading`'s contract, then decide whether to execute it.
4. Resolve open questions for `rf_rename-logduration-to-omniprobe` (library name, env var prefix,
   backward compat).
5. Unblock `rf_clang-format-consistency` — coordinate with team for format commit.
6. Make design decisions for `rf_test-organization`.

## Project-Level Risks

- **Test-environment variables are set, and two of them do not travel between nodes.**
  `TRITON_DIR` is architecture-independent (verified 2026-09-08: the Triton suite passes on
  gfx950 using a tree built on gfx90a) and is in `.claude/settings.local.json`'s `env` block.
  `INSTRUMENTED_ROCBLAS_LIB_DIR` and `INSTRUMENTED_HIPBLASLT_LIB_DIR` are **gfx90a-only** and
  fail with `not ISA compatible with this GPU` elsewhere, so `.untracked/test-env.sh` exports
  them only when the architecture matches — `source` it rather than setting them by hand.
  **The values live only in `.untracked/test-env.sh` and `.claude/settings.local.json`, both
  gitignored** — they are personal absolute paths and this repository is public. Do not copy them
  into a tracked file; refer to the variable names instead.
- **`build/` is a gfx90a tree.** Running it on a gfx950 node produces silent non-dispatch, not an
  error — which is what manufactured both corrected "defects" above. Build for the node you are on
  (`build_gfx950/` exists but lacks the Triton plugin), and check `rocminfo` before believing a
  test result.
- **A latent suite-classifier bug.** `tests/run_all_tests.sh:59` marks a whole suite as *skipped*
  if the string `SKIP` appears anywhere in its output, and `tests/rocblas_hipblaslt/run_test.sh:220`
  emits one mid-run. It has not fired — the Tensile search at `run_test.sh:86` matches on filename
  glob plus a `__amd_crk_Cijk` symbol check rather than on architecture, so it finds the gfx90a
  hsaco even on gfx950 — but it would fire on a build without instrumented Tensile kernels. Any
  criterion demanding `Suites skipped: 0` inherits it.
- **A log-line rename silently re-points every assertion written against it.** Cost this
  repository twice in one packet: AC-9's original check counted `Adding` lines and would have been
  satisfied by the rename alone, and `tests/library_filter_chain/run_test.sh` proved an exclusion
  worked by asserting the *absence* of an `Adding` line, which after the rename could no longer
  fire at all. When changing a log string, grep the tests for it in both directions — presence
  checks fail loudly, absence checks pass silently.

## Framework state (2026-08-25)

- **Upgraded to AMP v0.6** from v0.3, three versions in one run. The six suspended packets have
  intact contracts; resume with `/workflow-resume <id>`.
- **This repository declares a plugin:** `plugins: ["../amd-agent-infra"]` in
  `.agents/project.json`. **That names a private repository in this public one, and it was
  deliberate** — owner decision 2026-08-25, taken after measuring that the name appeared in zero
  commits of this repo's published history. It names no host, gateway, model, cluster, port or
  proxy. Recorded upstream as `[SEAM-Q5]` in `agentic_meta_project`'s `pm-decisions.md`. **Do not
  "fix" it by deleting the line** — the disclosure is in git history either way, and the
  declaration is what gives the framework's plugin seam a live consumer.
- **Local failure modes are `FM-L<n>`.** This repo's own `FM-4` collided with the framework's and
  is now `FM-L1`. Note `.agents/improvement/failure-modes.md` is a *preserved* file, so it never
  receives framework updates — its convention section is a dated snapshot and it carries none of
  the framework's FM-5..FM-13.

## Recent Decisions

- **Skip the private code-object load for application-loaded HIP fat binaries** (2026-09-08,
  `bf_hip-duplicate-code-object-load`). Chosen over reversing the first-writer precedence or
  building the deferred `KernelRegistry`. Only the *executable-loading* half of `coCache::addFile`
  is skipped; `extractCodeObjects` still runs, because `kernel_co_map_` and `KernelArgHelper` need
  the temp files. Triton keeps the full path — its instrumented kernels exist nowhere else.
- L2 cache miss investigation (2026-07-29): MI300X L2 confirmed per-XCD (not per-SE); `SC[1:0]`
  scope model + MTYPE bypass levers documented; standalone host-pinned coherence test passes on
  MI350X. See `.untracked/l2-cache-miss-investigation.md` and `.untracked/amd_gpu_memory_system.md`.
- Completed ft_omniprobe-python-api (2026-07-20): Python API at `omniprobe/api/`, structured JSON
  schemas for MemoryAnalysis and BasicBlockAnalysis. Enables IntelliKit integration.
- Completed rf_triton-v3.7-bump (2026-07-13): Triton bumped v3.6.0 → v3.7.1, all tests pass.
- PM restructured (2026-04-27): merged plugins+comms-mgr → handler-pipeline; created build-system
  unit.

## Reading Path for the Next Session

1. `.agents/state/current-focus.md`
2. `.agents/state/active-workflows.md`
3. `.agents/workflows/done/bf_hip-duplicate-code-object-load/dossier.md` — if touching
   `src/interceptor.cc`, `src/utils.cc`, or any kernel-discovery / code-object-loading path
4. `.untracked/l2-cache-miss-investigation.md` — if continuing SQTT/L2 work
5. `.untracked/amd_gpu_memory_system.md` — memory hierarchy, scope/MTYPE model, Part 4
   atomics/coherence placeholder

# Current Focus

## State after 2026-10-27 — read first

- **Triton is now v3.8.0** (`7f18d4b`). Toolchain image and `build.yml` green against it; locally
  11/11 on gfx90a. The **local default test environment now uses the v3.8.0 tree too** (`build/`
  reconfigured, `TRITON_DIR` repointed in the two gitignored env files). The v3.7.1 tree is still on
  disk but no longer default — delete it when convenient. Keep env and pin in step.
- **Issue #43 closed, PR #44 merged** (`b12d7f0`). The triple match it raised was fixed first
  (`e6db747`), ahead of the Triton bump that would have needed it.
- **jq is now a build prerequisite** (`e18e4bb`): `triton_install.sh` checks for it, and verifies the
  built LLVM commit against the pin.
- **`main` is branch-protected** (no force-push/deletion, admins included). The agent may now push;
  force/delete/mirror/`+refspec` pushes are denied in `.claude/settings.local.json`.
- **Next: `bf_pyhandler-gil`** in a fresh session — still the last thing blocking IntelliKit.
- New draft packet `bf_library-filter-chain-silent-pass` (a suite that can pass having tested nothing).
- Detail lives in PM: `build-system` (pin, CI, image checkpoint, soname hazard), `instrumentation`
  (#44, triple), `testing` (testing-another-tree traps), `pm-decisions`.

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

Both were artefacts of running gfx90a binaries on a gfx950 GPU. Measured on `k005-005.hpcfund`
(MI210 / gfx90a):

> **Amended 2026-10-26.** This section used to say such a binary "fails to dispatch silently and
> produces exit 0 with no output". **The silence was not the architecture mismatch — it was
> `bf_exit-status-not-propagated`.** Measured directly on gfx950,
> `build/tests/test_kernels/simple_heatmap_test` **dies of SIGSEGV and exits 139**. The exit 0
> only ever appeared when the binary was observed *through* omniprobe, which discarded the child's
> status. That packet's fix (`c5aec00`) removes the instrument that manufactured the misreading,
> so this failure mode is now loud. The two corrections below still stand — they were about the
> defects not existing, which is unaffected — but the mechanism named here was wrong.

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

- **Unblock IntelliKit** — `bf_pyhandler-gil` is now the only packet standing in the way.
  `bf_exit-status-not-propagated`, the other half, **completed 2026-10-26**. Both were filed from
  the IntelliKit sidecar and that project depends on both fixes. This is the priority.
- Fix the `.intern.<hash>` clone-name defect (bf_intern-clone-name — active, queued second).
  **Its dossier's line references into `InstrumentationCommon.cpp` are stale** — `e6db747` and
  `b12d7f0` edited that file after its Base Commit `5b9425f`. Re-find `:211` etc.; do not trust them.
- Fix `tests/library_filter_chain/run_test.sh` silently passing (bf_library-filter-chain-silent-pass
  — draft; diagnosed, reproduced by its `acceptance.sh`, not fixed).
- Review and finalize Omniprobe whitepaper (ft_whitepaper-omniprobe — awaiting user review).
- Adopt lazy kernelDB loading in the interceptor (rf_lazy-kerneldb-loading — **contract needs
  revisiting first**, see above).
- Complete exact-architecture bitcode selection (rf_exact-arch-bitcode — ready to start).
- Purge logDuration naming from the codebase (rf_rename-logduration-to-omniprobe — needs open
  questions resolved).

## Active Workflows

**Two active bugfixes**, both promoted 2026-09-08, neither with any production code written yet.
Six suspended. See `.agents/state/active-workflows.md`.

| Packet | Needs a GPU? | Why it is queued where it is |
|---|---|---|
| `bf_pyhandler-gil` | yes, arch-matched | IntelliKit depends on it; the Python handler path is unusable without it |
| `bf_intern-clone-name` | yes, gfx90a | found in-house; no external consumer waiting |

**Take `bf_pyhandler-gil` first.** Owner direction 2026-09-08 put the two IntelliKit-filed
packets ahead of `bf_intern-clone-name`; one of those is now done, so this is the remaining one.

**Both start with the same step 0** — re-stamp the `Base Commit` to `HEAD` and commit that alone.
All three were promoted in one commit, so each currently reports the others' packet directories
as out-of-scope writes. The check is right; the subject is wrong. Each handoff explains it.

**`bf_pyhandler-gil` also gets a simplification for free.** Its AC-4 was written to check the
instrumented target's *own* exit status, as a workaround for
`bf_exit-status-not-propagated` being unfixed. It is fixed; AC-4 may check omniprobe's status
directly. The packet text was deliberately left unamended — that write belongs to the packet.

**Completed 2026-10-26: `bf_exit-status-not-propagated`.** Packet in `done/`. `omniprobe` now
propagates the child's exit status (`128 + signal` for signal deaths, JSON finalized before
exit). Closed GitHub issue #41.

## Immediate Next Recommended Actions

*Updated 2026-10-27 — the list below this note predates the Triton bump and #43/#44, which are
both done. In order now: (a) `bf_pyhandler-gil`; (b) `bf_intern-clone-name`, after re-finding its
line references; (c) `bf_library-filter-chain-silent-pass`, promote and execute. Parked by the
owner, do not act on unprompted: an upstream Triton report about `build-llvm-project.sh`'s silent
`null`-pin failure (owner is consulting colleagues), and fork-PR CI / triage of external PRs
#37–#40, #42 (needs owner decisions; see `build-system`). The original list follows.*

1. **~~File a packet for the `.intern.<hash>` clone-name defect.~~ FILED 2026-09-08 as
   `bf_intern-clone-name`** — now **active**, promoted the same day. Queued **third**, behind the
   two IntelliKit-blocking packets; next step is its own Plan Of Record step 1. **The hypothesis below was confirmed — and the
   investigation then found it was only half the story.** Read the packet's `dossier.md`
   § Background before working on it; the corrections are summarised under *"What the probe
   actually found"* after the original framing.

   It was an explicit non-goal of the completed bugfix, and it is the quieter cousin of it:
   partial data loss on a run that otherwise succeeds. Less dangerous than the `__constant__`
   bug, because it does print a line saying it gave up.

   **Symptom** (PENNANT `sedovsmall`, `cstop 1`):

       No instrumented alternative found for gpuMain5(double, double const*, double const*)
         [clone .intern] [clone .de1b0b8eba669612] [clone .kd]

   Those kernels run their originals and produce no analysis data. `getInstrumentedName`
   (`src/utils.cc:117`) rebuilds the clone name by finding the last `)`, splicing in `, void*`, and
   prepending `__amd_crk_`. It has no notion of `[clone …]` decorations — they sit outside the
   signature and are carried through verbatim — so the name it builds matches no symbol in the
   code object.

   **A small reproducer should be enough; PENNANT is probably not needed.** Found 2026-09-08, and
   the correlation is exact:

   | kernel | declaration in `pennant/src/HydroGPU.cc` | instruments? |
   |---|---|---|
   | `gpuMain2` | `void gpuMain2(...)` — external linkage | **yes** |
   | `gpuMain1`, `gpuMain3_*`, `gpuMain4`, `gpuMain5` | `static void …` | **no** |

   This agrees with the mangled symbol recorded in the completed packet's dossier,
   `_ZL8gpuMain5dPKdS0_` — the `L` in `_ZL` is Itanium ABI for **internal linkage**. The
   hypothesis, therefore: *a `static` (or anonymous-namespace) `__global__` kernel under
   `-fgpu-rdc`*. Device linking merges translation units, so a static kernel's symbol has to be
   made globally unique, and clang appends `.intern.<hash>` to do it.

   **Measured vs inferred, because the distinction decides the first step.** The `static` /
   non-`static` correlation and the `_ZL` mangling are measured. That `-fgpu-rdc` plus internal
   linkage is *sufficient* to produce `.intern.<hash>` is inferred from those two facts and has
   **not** been tested.

   **Cheapest first move:** write a file with one `static __global__` kernel and one ordinary one,
   compile it, and `llvm-nm` for a `.intern.` symbol. If it is there, PENNANT is redundant except
   as secondary confirmation. If it is not, the trigger is something else and this whole framing is
   wrong — which is worth knowing before any packet is written around it.
   - `tests/test_kernels/*` are **already compiled with `-fgpu-rdc`** (seen in the build log
     2026-09-08), so the new test does not have to arrange the flag.
   - `tests/test_kernels/filter_semantics_test.hip` is the template — the completed packet added
     it as exactly this kind of two-kernel "this one is instrumented, that one is not" fixture.

   ### What the probe actually found (2026-09-08, gfx90a, ROCm 7.2.0)

   The cheap first move above was run. It worked, and the answer was more interesting than
   expected. Everything here is measured; evidence in `.untracked/scratch/intern-probe/`.

   - **Framing confirmed.** Internal linkage **and** `-fgpu-rdc` are both necessary; neither
     alone produces `.intern.<hash>`. Anonymous-namespace behaves exactly like `static`. PENNANT
     is redundant — a three-kernel in-repo fixture reproduces it.
   - **The hash is per-translation-unit, not per-symbol**, so every internal-linkage kernel in a
     TU shares one fate. It also changes with compile flags (same source: `26db06f5c7a9cf0b`
     plain, `69c48a2e06e7f383` with the instrumentation plugin). **No test may pin a literal
     hash.**
   - **The instrumentation pass does emit clones for these kernels.** Nothing is missing from
     the code object; this is purely a name-reconstruction and lookup-key defect.
   - **The defect is intermittent at ~37.5%, and the deciding factor is one character.**
     libstdc++'s clone-suffix grammar accepts `.<identifier>` and `.<all-digits>` but rejects a
     digit-leading token containing letters. A hash beginning `a`–`f` demangles, so the original's
     key carries `[clone …]` decorations and the lookup misses. A hash beginning `0`–`9` fails to
     demangle, `getInstrumentedName` takes its mangled branch, and it **works by accident**.
     Measured: 6 of 16 padding variants were letter-leading, matching the predicted 6/16, and
     `omniprobe -i` fails on those and succeeds on the rest.
   - **There are two defects and they cancel.** `InstrumentationCommon.cpp:211` appends `Pv` to
     the end of the whole symbol, *after* the `.intern.<hash>` suffix, producing a name that is
     not well-formed and never demangles. So the feature works precisely when both demangles fail
     together. **Fixing either side alone regresses the other half of the cases — and the half
     that currently works is the majority.**

   The practical warning for anyone writing the regression test: a reproducer built the obvious
   way passes ~62% of the time *while the defect is fully present*. This is the same shape as the
   log-line-rename hazard under Project-Level Risks below — an assertion that cannot fire.

   Note the PENNANT tree (`branch mi300a` at `088a2a3`) has uncommitted build fixes in its working
   directory, so the original reproducer is **not** reproducible from a clean checkout. That is a
   second reason to prefer an in-repo one.
2. ~~**Execute `bf_exit-status-not-propagated`**~~ — **DONE 2026-10-26.** Packet in `done/`,
   GitHub issue #41 closed.
3. **Execute `bf_pyhandler-gil`** — GPU and arch-matched build required. **This is now the top
   recommended action**: it is the last thing blocking IntelliKit. Note its scope was
   decided by the owner: the Python bridge ships as a **plugin** under `plugins/`, and the core
   library must not acquire a libpython dependency. AC-6 enforces that.
4. Execute `rf_exact-arch-bitcode` — upstream dependency resolved, rewrite `getBitcodePath()`.
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

- **`fuseblk` does not automatically mean "relocate the build to `/tmp`".** The machine-level
  filesystem notes flag `virtiofs` and `fuseblk` as lacking mmap support, breaking
  `hipModuleLoad` under ROCm 7.2, with building to `/tmp` recorded as the workaround. Measured
  2026-10-26 on `k006-004-v3.hpcfund`, where `/work1` and `/home1` are both `fuseblk`: **all
  eleven suites passed straight from the in-repo build tree**, GPU-dispatching ones included, with
  no relocation. The hazard is real but not universal, and which operations actually trip it is
  uncharacterised. Treat the workaround as a response to an observed failure, not a precondition
  — and do not read a green run on `fuseblk` as evidence the hazard is gone either.
- **Test-environment variables are set, and two of them do not travel between nodes.**
  `TRITON_DIR` is architecture-independent (verified 2026-09-08: the Triton suite passes on
  gfx950 using a tree built on gfx90a) and is in `.claude/settings.local.json`'s `env` block.
  `INSTRUMENTED_ROCBLAS_LIB_DIR` and `INSTRUMENTED_HIPBLASLT_LIB_DIR` are **gfx90a-only** and
  fail with `not ISA compatible with this GPU` elsewhere, so `.untracked/test-env.sh` exports
  them only when the architecture matches — `source` it rather than setting them by hand.
  **The values live only in `.untracked/test-env.sh` and `.claude/settings.local.json`, both
  gitignored** — they are personal absolute paths and this repository is public. Do not copy them
  into a tracked file; refer to the variable names instead.
- **`build/` is a gfx90a tree, configured against Triton v3.8.0's LLVM (since 2026-10-27).**
  Running it on a gfx950 node produces a crash (now loud, since exit-status propagation landed), not
  results. Build for the node you are on (`build_gfx950/` exists but lacks the Triton plugin and
  predates the bump), and check `rocminfo` before believing a test result. `build_t380/` is a
  leftover from the bump validation, now redundant with `build/`.
- **A green suite only counts if it tested the tree and Triton you meant.** Check the `Plugin:` and
  `Triton venv:` lines and grep for the degradation warnings; see the `testing` unit's
  "Testing a tree other than `<repo>/build`".
- **`.claude/session_init_primes.json` is a dead pre-AMP leftover** with stale values (v3.7.1 paths,
  a `lib/` that should be `lib64/`). Nothing live reads it. Do not use it as a source of truth.
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

- **2026-10-26/27 — Triton v3.8.0 bump, #43/#44, branch protection.** Six decisions recorded in
  `.agents/pm/pm-decisions.md` (jq + outcome verification; two-stage image; fix #43 item 1 before
  merging #44; `isAMDGCN()` via parsed triple; branch protection + agent push; test env tracks pin).

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

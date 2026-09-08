# Run-Log

Append an entry after every meaningful execution step. This is not optional. If the session is
interrupted, this log is the only record of progress.

## Log Entries

### 2026-09-08

- **Actor**: claude
- **Planned step**: Create a bugfix packet for the HIP duplicate-code-object load that zeroes
  `__constant__` memory in instrumented clones, discovered 2026-09-01 during PENNANT profiling.
- **Action taken**: Confirmed no prior seed or workflow existed for this defect —
  `.agents/workflows/seeds/`, `draft/`, `active/` and `blocked/` hold only their READMEs, and
  `command grep -rniE "__constant__|coCache|addFile|registerRuntimeKernel|zeroed" .agents/`
  returns hits only under `.agents/kt.archive/`, none describing this as a defect. Then read
  every source anchor cited by the originating write-up and created this packet.
- **Result**: success. Packet created at
  `.agents/workflows/draft/bf_hip-duplicate-code-object-load/` with dossier, handoff, run-log,
  artifacts and acceptance script.
- **Files touched**: this packet's five files only. No source, no test, no doc.
- **Verification**: 20 source anchors read directly at `74c6ed2` and confirmed — full table in
  `handoff.md` § Last Verified. **One anchor in the write-up was wrong**: `findAlternative` is at
  `src/utils.cc:706`, not `:945` (that line is `KernelArgHelper::KernelArgHelper`). The dossier
  carries the correction. The structural claim the anchors support — that the `-k` regex
  `continue` at `src/utils.cc:616` sits *before* both the `lookup_map_` insert (640–644) and the
  `kernel_co_map_` insert (645), so the filter gates only the `addFile` writer and not
  `registerRuntimeKernel` — was confirmed by reading `src/utils.cc:600–650` in full.
- **Criteria impact**: none met. AC-1 through AC-9 all outstanding; `acceptance.sh` fails by
  design while the packet is in draft.
- **Blocker / Risk**: `rf_lazy-kerneldb-loading` (suspended) plans to delete
  `src/interceptor.cc:802–808`, the block this defect's workaround depends on, and declares "No
  changes to coCache" as an invariant. Both assumptions predate this finding. Recorded in the
  dossier's Dependencies and in `handoff.md`; recorded as an overlap in
  `.agents/state/active-workflows.md`.
- **Note**: the runtime behaviour was **not** re-reproduced in this session. All measurements
  quoted in the dossier come from the 2026-09-01 PENNANT session and are attributed as such.
  Plan step 1 reproduces at HEAD before any change is made.

### 2026-09-08 (later)

- **Actor**: claude
- **Planned step**: Run the new `acceptance.sh` once to confirm it fails honestly for a draft
  packet, rather than assuming it does.
- **Action taken**: Ran the gate. It surfaced two defects **in the gate itself**, both fixed:
  1. **AC-5 reported a false PASS.** `tests/triton/run_test.sh` exits 0 while printing
     `SKIP: TRITON_DIR not set`, so checking its exit status alone laundered a skip into a pass —
     and it did so on the single largest regression risk of this change, since
     `coCache::addFile` exists for Triton and this packet changes when it is used. The check now
     greps for `SKIP:` and fails on it.
  2. **AC-4 was unachievable and would have read as a regression caused by this workflow.**
     `tests/run_all_tests.sh` is not green at HEAD: 6 suites run, 1 passed, **4 skipped** for
     unset environment variables, **1 failed** — Handler tests, on `Expected pattern not found:
     'memory heatmap report'`. Rewrote AC-4 against a recorded baseline, added
     `baseline-run_all_tests.txt`, and made a skipped suite an explicit FAIL rather than a pass.
- **Result**: success. Second run: `1 passed, 0 weak, 0 judgement, 9 failed`, exit 1 — correct
  for a draft packet with no implementation. AC-1 passes (the existing `build/` tree builds
  clean) and everything else is honestly outstanding.
- **Files touched**: this packet's `acceptance.sh`, `dossier.md`, `baseline-run_all_tests.txt`,
  `run-log.md`. Evidence written to `.untracked/bf_hip-dup-co/`. No source, no test, no doc.
- **Verification**: the gate itself, run twice — before and after the corrections.
- **Criteria impact**: AC-4 and AC-5 restated (both **tightened**, not weakened: a skip that
  previously counted as success now fails). Recorded here rather than under
  `## Proposed Spec Changes` because strengthening a criterion is not a contract change; no
  criterion was weakened, redefined, or substituted.
- **Blocker / Risk**: two environment gaps now on record. (a) `TRITON_DIR` and
  `INSTRUMENTED_ROCBLAS_LIB_DIR` are unset on this node, so two thirds of the suite does not run
  and AC-4/AC-5 cannot be satisfied until that is fixed. (b) `.gitignore` contains `build` only,
  so the untracked `build_gfx950/` and `build_v3.6.0_llvm/` trees make `ac_check_write_scope`
  emit a 74 KB out-of-scope verdict listing every file in them — this will drown real scope
  findings for **every** packet in this repository, not just this one. A one-line `.gitignore`
  fix, deliberately not made here: it is outside this packet's purpose and belongs in its own
  change.

### 2026-09-08 (later still)

- **Actor**: claude
- **Planned step**: Check whether a fresh `/session-init` in this repository would actually
  surface this packet's two coordination warnings, rather than assuming the `active-workflows.md`
  note was sufficient.
- **Action taken**: Read `.agents/skills/session-init/SKILL.md` § Required Reads. Both
  `current-focus.md` and `active-workflows.md` are `[required]`; the dossier and run-log are
  **not** read unless a workflow is being resumed. So the collision note landed, but the
  `.gitignore` and test-suite findings would not have been seen by anyone who was not already
  opening this packet. Worse, `current-focus.md` still listed *"Execute rf_lazy-kerneldb-loading"*
  as **Immediate Next Recommended Action #1** and described it as "ready to start" — pointing the
  next session straight at the packet whose premise this defect invalidates, and directly
  contradicting the warning added to `active-workflows.md`.
- **Result**: success. Updated `current-focus.md`: new section at the top describing the defect
  and the collision; the stale "ready to start" line annotated; recommended action #1 replaced
  and the superseded one kept visible rather than deleted, so the change is legible; the
  `.gitignore` and test-suite facts added under Project-Level Risks; a conditional entry added to
  the reading path.
- **Files touched**: `.agents/state/current-focus.md`, `.agents/state/active-workflows.md`
  (framework-allowlisted; no scope amendment required).
- **Verification**: `session-init`'s required-reads list read directly, not recalled. Both files
  are on it.
- **Criteria impact**: none — coordination state, not acceptance criteria.
- **Blocker / Risk**: none new. Note for whoever promotes this packet: the two Project-Level
  Risks recorded in `current-focus.md` are repository-wide facts that outlive this packet, and
  should not be deleted when it completes.

### 2026-09-08 (promotion)

- **Actor**: claude
- **Planned step**: Run `/workflow-readiness-check` on this packet and, if it passes, promote
  `draft/` → `active/`. User authorised the promotion in advance, conditional on the check.
- **Action taken**: Ran the full readiness check — structure, all seven dossier sections, AC
  coverage against `acceptance.sh`, judgement-marker reasons, write-scope conflicts, base-commit
  stamp, handoff next step. **Result READY**, no structural failures. Then moved the packet to
  `.agents/workflows/active/`, set `- Lifecycle State: active`, stamped
  `- Base Commit: 74c6ed2dded669fe797dff5234dee4a7d1eef8ab`, and corrected the now-stale `draft/`
  paths in this packet's `acceptance.sh` header and `handoff.md`.
- **Result**: success. Packet is active and unowned.
- **Files touched**: this packet's `dossier.md`, `handoff.md`, `acceptance.sh`, `run-log.md`;
  `.agents/state/active-workflows.md` and `.agents/state/current-focus.md` (both
  framework-allowlisted). No source, no test, no doc.
- **Verification**: `acceptance.sh` **run**, not assumed — `1 passed, 0 weak, 0 judgement,
  9 failed`, `ac_finish` last, exit 1. Correct for a packet with no implementation. Also audited
  every text-searching check for the pattern-collision failure mode: `AC-5` (`SKIP:`), `AC-9`
  (`^Adding `) and `AC-4` (the suite tally) all anchor to literals the tools *emit*, into
  run-generated logs under `.untracked/` — none reads source or this packet's own directory, so
  neither a false FAIL nor a vacuous PASS is reachable through them. Every check that is not
  already failing is gated on an artefact that does not exist yet.
- **Criteria impact**: none. AC-1 passes (pre-existing `build/` tree compiles); AC-2…AC-9
  outstanding.
- **Blocker / Risk**: four carried forward for the executor.
  1. **`AC_BUILD_DIR` defaults to `build/`, the gfx90a tree.** AC-1 passed against a build
     unrelated to the reproduction; the defect has only been seen on gfx950. Export
     `AC_BUILD_DIR=$PWD/build_gfx950`. Now stated in `acceptance.sh`'s header and `handoff.md`.
  2. **AC-4 and AC-5 are unsatisfiable on this node as configured** — `TRITON_DIR` and
     `INSTRUMENTED_ROCBLAS_LIB_DIR` unset, 4 of 6 suites skip. Blocks completion, not promotion.
  3. **AC-4 requires `Suites skipped: 0`, and `tests/run_all_tests.sh:59` marks a suite skipped
     if `SKIP` appears anywhere in its output.** `tests/rocblas_hipblaslt/run_test.sh:220` emits
     a mid-run `SKIP` when no instrumented Tensile `.hsaco` files are found, so that suite can
     read as fully skipped even with both variables set. Check this before concluding AC-4 is
     failing because of this change. Found during the readiness check; not previously recorded.
  4. **The reproducer is untracked and in another repository.** Confirmed present at
     `../pennant-amp-sidecar/.untracked/omniprobe-2026-09-01/argprobe_g.hip` (2077 bytes,
     2026-09-01). Copy it into `tests/` early — plan step 7 does this, but the whole packet
     depends on a file with one untracked copy.

### 2026-09-08 (test environment resolved)

- **Actor**: claude
- **Planned step**: Recover the values of `TRITON_DIR` and `INSTRUMENTED_ROCBLAS_LIB_DIR` used in
  prior sessions on an MI210 node, and set them on this node, so that AC-4 and AC-5 stop being
  unsatisfiable. User asked whether the directories are architecture-sensitive.
- **Action taken**: Located the candidate trees, then ran the full suite with all three variables
  set rather than reasoning about whether they would work.
- **Result**: success, with a **split answer to the architecture question**.
  - `TRITON_DIR` is **architecture-independent**. Triton JIT-compiles
    for the GPU present at run time. The Triton suite **PASSED on gfx950** using a tree built and
    previously used on gfx90a. **AC-5 is now satisfiable on this node.**
  - `INSTRUMENTED_ROCBLAS_LIB_DIR` and `INSTRUMENTED_HIPBLASLT_LIB_DIR` are
    **architecture-dependent**, and the available trees are gfx90a-only:
    `Kernels.so-000-gfx90a-xnack{+,-}.hsaco`, `TensileLibrary_gfx90a.yaml`, `*_gfx90a.co`. On this
    gfx950 node they fail at run time — not skip, not silently pass:
    `Looks like .../Kernels.so-000-gfx90a-xnack-.hsaco is not ISA compatible with this GPU`, then
    `rocBLAS error: Cannot read .../TensileLibrary.yaml: Illegal seek for GPU arch : gfx950`.
- **Files touched**: `.claude/settings.local.json` (added an `env` block with `TRITON_DIR`),
  `.untracked/test-env.sh` (new, sourceable, arch-detecting). Both paths are gitignored, which
  matters: every value here is a personal absolute path and this repository is public. No source,
  no test, no doc, nothing in this packet's write scope.
- **Verification**: `tests/run_all_tests.sh`, run twice on k007-005-v2 (MI350X/gfx950) at
  `74c6ed2`.

  | environment | run | passed | skipped | failed |
  |---|---|---|---|---|
  | all three unset (the recorded baseline) | 6 | 1 | 4 | 1 |
  | all three set | 6 | **2** | **0** | 4 |

  Passing suites with the variables set: Library filter chain, **Triton integration**. Failing:
  Handler tests (pre-existing, per the baseline) plus hipBLASLt instrumentation, rocBLAS
  integration, and rocBLAS + hipBLASLt combined — all three on the ISA mismatch above.
- **Criteria impact**: none met, none changed. But the **shape** of AC-4's problem has changed and
  the next agent must not misread it. AC-4 requires no skipped suites *and* no regression against
  `baseline-run_all_tests.txt`, and that baseline was recorded with the variables unset. Setting
  them satisfies the first clause and appears to violate the second — three suites move from
  `skipped` to `failed` for reasons that have nothing to do with this bug. **Do not treat that as
  a regression, and do not weaken AC-4 to make it go away.** The baseline needs re-recording on
  this node with the variables set before AC-4 compares like with like; that is a change to the
  evidence, not to the criterion, and it is left for the user to approve rather than done here.
- **Correction to risk 3 of the promotion entry above.** That entry warned that
  `tests/rocblas_hipblaslt/run_test.sh:220`'s mid-run `SKIP` could make a suite that ran tally as
  skipped. The code property is real, but the full run measured here shows it **did not fire**:
  the Tensile search at `run_test.sh:86` matches on filename glob plus a `__amd_crk_Cijk` symbol
  check rather than on architecture, so it finds the gfx90a hsaco even on gfx950. Zero
  occurrences of `SKIP` in the whole run with the variables set. Treat it as latent — it would
  fire on a build without instrumented Tensile kernels — not as an active obstacle.
- **Blocker / Risk**: AC-4 cannot reach "0 skipped and no failures beyond baseline" on a gfx950
  node with the libraries that exist today. Either execute this packet on a gfx90a/MI210 node,
  or rebuild instrumented rocBLAS/hipBLASLt for gfx950 — real work, not configuration. AC-5, the
  criterion the dossier calls the change's largest regression risk, is unblocked either way.

### 2026-09-08 (reproduction — plan step 1)

- **Actor**: claude
- **Planned step**: Plan step 1 — reproduce the defect at HEAD before changing anything.
- **Action taken**: Built `build_gfx950` (exit 0). Copied the reproducer into the repository as
  `tests/test_kernels/constant_memory_test.hip` — body unmodified, provenance header added —
  because it existed in exactly one untracked copy outside this repo and the whole packet depends
  on it. Also copied the PENNANT run log in as `pennant-rep1.log` for the AC-9 evidence trail.
  Compiled with the same flags the repo's own test kernels use:

      hipcc -fgpu-rdc -g --offload-arch=gfx950 \
        -fpass-plugin=build_gfx950/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so \
        tests/test_kernels/constant_memory_test.hip -o /tmp/constant_memory_test

  Binary written to and run from `/tmp` (XFS): `/work1` and `/home1` are **fuseblk** on this node,
  which does not support mmap. Ran plain, then under `omniprobe -i` with **no** `-k`.
- **Result**: **success — the defect reproduces exactly as the dossier describes.**

      plain run:          clone saw: cdata=0x7f3d69400000 cscalar=12345 scale=2.5
                          → kernargs OK, __constant__ OK
      omniprobe -i:       clone saw: cdata=0x0            cscalar=0     scale=2.5
                          → kernargs OK, __constant__ CORRUPT

  The clone is found and swapped in (`Found instrumented alternative for probe_g(...)`), the
  kernargs arrive intact, and both `__constant__` globals read as zero. This is the first time
  the behaviour has been observed at `74c6ed2` in this repository; every prior measurement came
  from the 2026-09-01 PENNANT session and was reported as that session recorded it. That gap is
  now closed.
- **Files touched**: `tests/test_kernels/constant_memory_test.hip` (new, in declared scope),
  this packet's `pennant-rep1.log`, `handoff.md`, `run-log.md`, and
  `.untracked/bf_hip-dup-co/adding-before.log`. No change to `src/` or `inc/`.
- **Verification**: the two runs above, on k007-005-v2 (MI350X/gfx950, ROCm 7.2.0), source tree
  at base commit `74c6ed2` — the two commits since (`fe66ff4`, `ef50230`) touch only `.gitignore`
  and `.agents/`, so no source moved under the reproduction.
- **Criteria impact**: none met. **AC-2's failing case is now demonstrated**, which is what makes
  AC-2 a real gate rather than an assertion — it is known to fail before the fix. Also captured
  the AC-9 pre-change baseline: **31 `Adding` lines** for a single-kernel HIP binary, against
  PENNANT's 95. Even a minimal program has 31 code objects duplicated into Omniprobe's private
  executable.
- **Blocker / Risk**: none new. Note the reproduction used `-fgpu-rdc`, matching the repo's own
  test kernels; the write-up reports the defect is identical without it, which has not been
  re-checked here.

### 2026-09-08 (design decision — plan step 3)

- **Actor**: claude
- **Planned step**: Plan step 3 — read `rf_unify-kernel-discovery` and choose between (a)
  reversing first-writer precedence, (b) skipping the duplicate load, or (c) the deferred
  `KernelRegistry`.
- **Action taken**: Read the archived packet in full, then read `coCache::addFile`
  (`src/utils.cc:503–660`) and the dispatch path (`src/interceptor.cc:780–832`) rather than
  relying on the dossier's summary. Ran two discriminating experiments on the in-repo reproducer.
- **Result**: **Decision — option (b), with a structural refinement that makes it smaller than it
  looked, and option (a) as the fallback.**

  **Experiment 1 — does the application's own executable actually serve a correct clone?**
  Run with a `-k` regex that does *not* match, so `addFile`'s insert is skipped and
  `registerRuntimeKernel` is the only writer of `lookup_map_`:

      -k "NOSUCHKERNEL"  → Found instrumented alternative … → __constant__ OK
      -k "probe_g"       → Found instrumented alternative … → __constant__ CORRUPT

  Both dispatch the clone. **Matching the filter is what breaks it.** This confirms the inverted
  `-k` semantics on a minimal case and, more importantly, proves the app's-own-executable path is
  correct — the fix has somewhere to land.

  **Experiment 2 — what does that path cost today?** Same two runs under `-a MemoryAnalysis`:

      -k "NOSUCHKERNEL"  → "Found 0 kernels."  no `kernel location:` line   4540 bytes of messages
      -k "probe_g"       → "Found 8 kernels."  kernel location: /tmp/…      2876 bytes

  So correct constants and DWARF correlation are **currently mutually exclusive**. That is the
  packet's crux, now measured rather than argued, and it is exactly what AC-8 exists to remove.

  **The structural finding.** `addFile` does two separable things and only the second causes the
  defect. (1) `extractCodeObjects()` writes temp files, feeding `kernel_co_map_` (kernelDB/DWARF)
  and `KernelArgHelper(co_file)` — note the helper is constructed from a **path**
  (`src/utils.cc:555`), so arg descriptors never needed the private executable. (2)
  `hsa_executable_create_alt` → `load_agent_code_object` → `freeze` (`src/utils.cc:528–551`)
  builds the private executable and fills `lookup_map_`/`kernels_` from its symbols; its
  `__constant__` segment is what nothing initialises. **Skip (2) for code the application has
  already loaded; keep both for Triton**, where the instrumented kernels exist nowhere else.
  That satisfies the Non-Goal without special-casing Triton by name.

  One consequence to design around: `kernel_co_map_` and `arg_map_` are currently populated
  *inside the loop over the loaded executable's symbols* (`src/utils.cc:585–650`), so decoupling
  them means sourcing the kernel-name list elsewhere — kernelDB already parses the extracted file,
  and `registerRuntimeKernel` already has the names.

  **Why not (a).** Reversing precedence so `registerRuntimeKernel` wins is a smaller change and
  would satisfy AC-2 and AC-3, but it leaves all 31 code objects still being loaded (AC-9 unmet)
  and leaves `kernel_co_map_` behind the `-k` filter (AC-8 unmet). It fixes the symptom this
  packet is named for and none of the rest. Keep it as the fallback if "has the application
  already loaded this code object?" cannot be answered reliably — the AMD loader API v1.01,
  already adopted by `rf_unify-kernel-discovery` for exactly this class of query, is the first
  thing to try.

  **Why not (c).** `rf_unify-kernel-discovery` considered the full `KernelRegistry`, chose the
  smaller augmentation deliberately ("achieves the goal with much smaller blast radius"), and
  this defect lives in that deferral — but reversing that call now would mean a large refactor of
  `src/interceptor.cc` while `rf_rename-logduration-to-omniprobe` and `rf_lazy-kerneldb-loading`
  both still claim that file. Wrong time, and not needed for this defect.
- **Files touched**: this packet's `dossier.md` (Open Question 1 marked resolved — Open Questions
  are not contract-controlled), `handoff.md`, `run-log.md`. No source.
- **Verification**: the four runs above on MI350X/gfx950, plus `src/utils.cc:503–660` and
  `src/interceptor.cc:780–832` read directly.
- **Criteria impact**: none met. The approach for AC-2, AC-3, AC-8 and AC-9 is now chosen and
  evidenced.
- **Blocker / Risk**: the decision rests on being able to tell "the application already loaded
  this code object" from inside `addFile`. If that proves unreliable, fall back to (a) and accept
  that AC-8 and AC-9 need separate treatment. Unverified as yet — it is the first thing plan
  step 4 must establish.

### 2026-09-08 (implementation — plan steps 4, 5, 6)

- **Actor**: claude
- **Planned step**: Steps 4–6: implement option (b), gate the clone swap on `-k` (AC-7), and
  populate `kernel_co_map_` regardless of the filter (AC-8).
- **Action taken**: First settled the question step 3 left open — **the runtime "has the
  application already loaded this code object?" test is not viable**, and the evidence is in the
  log we already had: all 46 `Adding` lines complete *before* `>>>>>>>> HSA intercept registered`,
  so at `addFile` time the application has loaded nothing into HSA and
  `iterate_loaded_code_objects` would have nothing to find. But the distinction turns out to be
  available **statically**, which is better: `getExecutablePath()` + `getSharedLibraries()`
  enumerate objects this process has already mapped, while `--library-filter` includes and the
  Triton JIT cache name files the application never loads. The call site at
  `src/interceptor.cc` already builds those two groups in one list; it now records the boundary
  index and passes the distinction down.

  Changes:
  - `inc/utils.h` / `src/utils.cc`: `coCache::addFile` takes `app_loads_object`. When set, it
    extracts the code objects and calls a new `coCache::indexCodeObjectFiles()`, which populates
    `arg_map_` and `kernel_co_map_` from the files alone and **never creates an HSA executable**.
    `KernelArgHelper::getKernelNames()` added so a file's kernels can be enumerated without one.
  - `src/interceptor.cc`: the file loop passes `app_loads_object` for the process's own binary
    and shared libraries, and `false` for `--library-filter` includes. Triton's `setLocation()`
    path is untouched and still gets the private executable, which is the Non-Goal.
  - `inc/interceptor.h` / `src/interceptor.cc`: the `-k` regex is compiled once at init and
    `runKernelInstrumented()` gates the clone swap, so a non-matching kernel keeps its original
    kernel object. `indexCodeObjectFiles()` deliberately does **not** apply the filter, so DWARF
    survives filtering (AC-8).
- **Result**: **success — the three-way tradeoff is gone.** Reproducer under `-a MemoryAnalysis`:

  | `-k` | `__constant__` | instrumented? | kernelDB |
  |---|---|---|---|
  | *(none)* | **OK** | yes | `Found 8 kernels`, source location present |
  | `probe_g` (matches) | **OK** | yes | `Found 8 kernels`, source location present |
  | `NOSUCHKERNEL` (no match) | **OK** | **no** — runs its original | `Found 0 kernels` (nothing instrumented, so nothing to correlate) |

  Compare the same table before the change: matching `-k` gave CORRUPT constants, non-matching
  gave correct constants but an empty kernelDB, and nothing gave both. AC-2, AC-3, AC-7 and AC-8
  all behave correctly on the reproducer now.

  Private code-object loads for the reproducer fell **31 → 0** (`.untracked/bf_hip-dup-co/`
  `adding-before.log` / `adding-after.log`).
- **Files touched**: `src/utils.cc`, `inc/utils.h`, `src/interceptor.cc`, `inc/interceptor.h` —
  all in declared scope. No test or doc yet.
- **Verification**: builds clean in both trees (`build_gfx950` and `build`, exit 0). Full suite on
  the `build/` tree with `TRITON_DIR` set, against the same tree and environment before the change:

  | suite | before | after |
  |---|---|---|
  | Library filter chain | PASS | PASS |
  | **Triton integration** | PASS | **PASS** |
  | Handler tests | FAIL (pre-existing) | FAIL (pre-existing) |

  **AC-5 is the one that matters here and it holds.** `coCache::addFile` exists for Triton and
  this change alters when it is used, so Triton passing is the evidence that the Non-Goal was
  respected. Note the Triton suite *fails* against `build_gfx950` for an unrelated reason — that
  tree was configured without `-DTRITON_LLVM`, so `libAMDGCNSubmitAddressMessages-triton.so` was
  never built there. Not a regression; checked before attributing it.
- **Criteria impact**: AC-2, AC-3, AC-7, AC-8 demonstrated on the reproducer; AC-5 verified
  unregressed; AC-1 builds clean. None of these are *met* until the regression tests of step 7
  exist and `acceptance.sh` decides them — the evidence above is manual.
- **Blocker / Risk**: **one honest weakness in AC-9's check, flagged for the human who rules on
  it** — AC-9 is already a `[judgement]` criterion, which is the right place for this. The check
  counts `^Adding ` lines, and this change makes the interceptor print `Indexing ` instead for
  files it no longer privately loads. So the 31 → 0 drop would also be produced by renaming the
  string and changing nothing else. The line is emitted from the same boolean that selects the
  behaviour, so they cannot drift by accident, but the check is weaker than a check anchored at
  the load site would be. Moving the emission inside `addFile` was considered and rejected: files
  whose `extractCodeObjects()` returns empty would silently lose their `Adding` line, which the
  library-filter tests read. The behavioural evidence for AC-9 is therefore the AC-2/AC-3/AC-8
  table above, not the count alone.

### 2026-09-08 (AC-9 check integrity)

- **Actor**: claude
- **Planned step**: Close the AC-9 weakness flagged in the previous entry, with user approval to
  amend the criterion's stated verification mechanism.
- **Action taken**:
  1. Added `Loading private code object <file>` to `coCache::addFile`, emitted **at the point an
     HSA executable is actually created**. Additive — `tests/run_library_filter_tests.sh`
     substring-matches `^Adding ` lines only, so nothing existing reads it.
  2. Rewrote AC-9's check: on a pure-HIP workload the private-load count must be **zero** while
     the indexed-file count is non-zero. Both are required — zero loads alone would also be true
     of a run that processed nothing.
  3. Amended AC-9 in the dossier and **dropped its `[judgement]` marker**. "Materially fewer"
     needed a human because it depended on the workload's shared-library count; "zero" does not.
- **Result**: success, and the exercise paid for itself twice over.

  **Non-vacuity demonstrated, not assumed.** Flipped `app_loads_object` to `false` — restoring
  the old behaviour with everything else identical — rebuilt, and ran the gate:

      FAIL  AC-9   1 code object(s) still loaded into a private executable on a pure-HIP workload

  Reverted, rebuilt, ran again:

      PASS  AC-9   31 code objects indexed, 0 loaded into a private executable

  A check that cannot fail is not a check; this one fails on the input it is supposed to fail on.

  **Found a real bug in the check while proving it.** The first version used
  `count=$(grep -c … || echo 0)` — the idiom inherited from the check being replaced. `grep -c`
  prints `0` *and exits 1* when it matches nothing, so the fallback appends a second line and the
  variable becomes `"0\n0"`, which is neither `-eq` nor `-ne` zero and derails every branch. It
  surfaced as `FAIL AC-9 0` against a build that should have passed. **The old check had the same
  idiom and would have misfired the moment its count reached zero — which is precisely the
  outcome it existed to detect.** Fixed to `|| true`.
- **Files touched**: `src/utils.cc`, this packet's `dossier.md`, `acceptance.sh`, `run-log.md`.
- **Verification**: the gate run three times — broken build (FAIL), fixed build (PASS), and after
  the counting fix (PASS). Tally now `3 passed, 0 weak, 0 judgement, 7 failed`.
- **Criteria impact**: **AC-9 amended and now met.** The amendment is a tightening on both axes:
  it cannot be satisfied by a rename, and it no longer needs a human ruling. Recorded here rather
  than under `## Proposed Spec Changes` because it was approved before being made, not proposed
  for later approval.
- **Correction to the previous entry, and to the dossier.** That entry reported "private
  code-object loads for the reproducer fell 31 → 0". **The 31 was files *considered*, not
  executables loaded.** The private-executable count went **1 → 0** for this reproducer. Same for
  the dossier's Background, which called PENNANT's 95 `Adding` lines "one per
  `.hip_fatbin`-carrying object" — `Adding` was printed for every file scanned, including the
  many with no fat binary. The defect is unaffected: one wrongly-initialised copy of the code
  object carrying the dispatched kernel is all it takes, and that one is confirmed. But claims
  about the *scale* of the duplication were overstated, and the new AC-9 counter is the number
  that should be quoted from here on. This is the second time a count in this packet turned out
  to measure files rather than loads.
- **Blocker / Risk**: none new. The AC-9 weakness recorded in the previous entry is closed.

### 2026-09-08 (regression tests — plan steps 7 and 8)

- **Actor**: claude
- **Planned step**: Step 7 — regression tests for AC-2, AC-3, AC-7, AC-8. Step 8 — full suite
  against the baselines.
- **Action taken**:
  - `tests/test_kernels/filter_semantics_test.hip` — two kernels, one strided (trips the L2
    report, so it carries a source-line attribution) and one coalesced (the kernel a `-k` regex
    does *not* match). Lets AC-7 and AC-8 be asserted **per kernel within one run** rather than
    inferred by comparing message volume across runs.
  - `tests/test_instrumented_kernel_common.sh` — shared helpers. Kernels are compiled for the
    architecture `rocminfo` reports, **not** for `CMAKE_HIP_ARCHITECTURES`. This was not
    hypothetical: the gfx90a `build/` tree's own test kernels dispatch nothing at all on this
    gfx950 node, silently, exiting 0 with no reports. Binaries are built into `/tmp` because
    `/work1` and `/home1` are fuseblk here and do not support mmap.
  - `tests/test_constant_memory_visibility.sh` (AC-2, AC-3) and
    `tests/test_kernel_filter_semantics.sh` (AC-7, AC-8).
  - All four modes added to `tests/run_all_tests.sh` as suites 7–10, so they keep running after
    this packet completes and its `acceptance.sh` is archived.
  - `acceptance.sh`: AC-2/3/7/8 now go through one helper that **fails on `SKIP:`** rather than
    trusting exit status — these tests skip like every other suite in the repo when hipcc or the
    plugin is missing, which is precisely the laundering AC-5 was already rewritten for.
- **Result**: success. Gate now reads **8 passed, 1 weak, 0 judgement, 1 failed**, and
  `tests/run_all_tests.sh` reports 10 suites: 6 passed, 3 skipped, 1 failed.
- **Verification**: **every test was run against a deliberately broken build, not just a working
  one.** With `app_loads_object` forced false and the `-k` gate forced open — the pre-fix
  behaviour, everything else identical:

  | test | fixed build | pre-fix build |
  |---|---|---|
  | `--no-filter` (AC-2) | PASS | **FAIL** |
  | `--with-matching-filter` (AC-3) | PASS | **FAIL** |
  | filter semantics (AC-7) | PASS | **FAIL** |
  | `--assert-dwarf` (AC-8) | PASS | **FAIL** |

  **AC-8 initially passed against the broken build — it was vacuous, and the probe is the only
  reason that was caught.** The source-line assertion holds pre-fix too, because the kernel the
  filter matches is the one being reported on, and pre-fix that kernel *did* get a code-object
  reference. The regression it was supposed to catch is that `kernel_co_map_` was populated
  behind the `-k` regex, so kernels *not* matching lost their reference entirely — the
  sacrificial-kernel problem. Added the discriminating check: with `-k kernel_strided`, pre-fix
  emits **one** `kernel location:` line and post-fix **two**. Both assertions are kept; only the
  new one distinguishes.

  AC-2's test carries a guard of the same kind: it asserts the clone was actually dispatched
  before checking `__constant__`. An uninstrumented run reads `__constant__` correctly by
  construction, so the check alone would pass against a build that had quietly stopped
  instrumenting anything.
- **Criteria impact**: **AC-2, AC-3, AC-7, AC-8 now met and machine-checked.** AC-6 met as
  `WEAK`, which is its documented ceiling. AC-1, AC-5, AC-9 still met. SCOPE passes.
- **AC-6, with two disclosures.** (a) The pre-change baseline was **reconstructed by disabling
  the fix**, not captured before the work began — plan step 2 was only partly done and the
  opportunity had passed. The reconstruction is behaviourally equivalent and is stated here
  rather than presented as an original measurement. (b) The check now strips the `timestamp`
  field before diffing. Every dispatch record carries wall-clock time, so an unnormalised diff
  **could never pass however correct the code was** — the dossier's verification strategy already
  called for normalising this output, and this is that step made narrow and explicit. Nothing
  else is filtered. Result: the two runs are otherwise byte-identical.
- **Blocker / Risk**: **AC-4 is the only failing criterion and it cannot be met on this node.**
  Three suites skip because the instrumented rocBLAS/hipBLASLt libraries are gfx90a-only and this
  is a gfx950 machine. Not a code problem and not fixable by configuration — it needs either an
  MI210 node or those libraries rebuilt for gfx950. Everything else in the packet is green.

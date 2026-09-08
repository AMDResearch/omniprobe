# Handoff

**Location**: `.agents/workflows/active/bf_hip-duplicate-code-object-load/handoff.md`

## Current Status

**Done. All acceptance criteria met.** The gate exits 0 — **9 passed, 1 weak, 0 judgement,
0 failed**, SCOPE clean. AC-4, the criterion the packet was handed off to a gfx90a node for,
passes. AC-6 is `WEAK`, which is its documented ceiling and not an outstanding item; its two
disclosures are recorded in `artifacts.md`.

Base commit `74c6ed2dded669fe797dff5234dee4a7d1eef8ab`. Measured on `k005-005.hpcfund`
(MI210 / gfx90a, ROCm 7.2.0), against the `build/` tree rebuilt at HEAD on that node.

## Next Exact Step

N/A — workflow complete. The three items below are follow-on work left deliberately outside this
packet, not blockers on it.

## What the closing session changed

Two things, both inside the declared `tests/` scope.

**1. A real regression, found where an environment gap was expected.** The first suite run on
gfx90a gave 10 run / 0 skipped / **1 failed** — `libfilter_exclude_nonexistent`, in the Handler
suite. The cause is this packet's own: `src/interceptor.cc:262` now prints `Indexing` rather than
`Adding` for files the application has already mapped, and the test grepped `^Adding ` for
`libm.so`. Library filtering itself is unchanged.

The half that did not show up in the tally matters more. `tests/library_filter_chain/run_test.sh`
proved an exclusion worked by asserting the *absence* of `Adding <BUILD_DIR>/libstatic_head.so`.
That library is application-loaded, so after the rename a broken exclusion would print `Indexing`
and the check **could no longer fire at all** — it passed, and would have kept passing however
broken the filter got. This is the same failure mode the packet already caught once from the
other side, when AC-9's original check counted `Adding` lines and was satisfiable by the rename
alone. A log-line rename silently re-points every assertion written against it, in whichever
direction that assertion runs.

Both now match `^(Adding|Indexing) `. The `libdynamic_*` presence checks are deliberately left
matching `Adding` alone: those arrive through a `--library-filter` include, are not mapped at
startup, and matching `Indexing` too would only weaken them. Non-vacuity was measured, not
assumed — 31 `Adding|Indexing` lines with `libm` present, 30 and no `libm` line when it is
excluded.

**2. The baseline was rebuilt, and it overturns two of this packet's standing beliefs.** Rather
than the in-place `app_loads_object = false` reconstruction proposed earlier — which reverts half
the change and would still run the four suites this packet *adds* — the base commit was built in
a worktree and its suite run there. At `74c6ed2` on gfx90a: **6 run, 6 passed, 0 skipped,
0 failed.**

- The Handler-tests failure this packet carried as a pre-existing defect, out of scope, is **not
  a defect**. It was a gfx90a binary failing to dispatch on a gfx950 GPU.
- The project-level risk "rocBLAS integration test broken — instrumented `sscal` not found",
  named as the one thing that could still block AC-4, **does not exist**. It passes at the base
  commit and at HEAD.

Neither was visible from the gfx950 baseline because four of six suites never ran there.

## Follow-on work this packet is deliberately not doing

1. **The `.intern.<hash>` clone-name defect** (originating write-up §3.2, `getInstrumentedName`
   at `src/utils.cc:117`). An explicit non-goal here. It now has a concrete reproducer: PENNANT
   `gpuMain3`/`gpuMain4`/`gpuMain5` at `cstop 1` print `No instrumented alternative found`.
   **Not yet filed as a packet.**
2. **`rf_lazy-kerneldb-loading` must not be resumed against its own premise.** Its plan step 4
   removes `src/interceptor.cc:802–808` and its invariants say "No changes to coCache" — now
   straightforwardly false of this tree. Revisit its contract *before* execution, not during.
3. **`tests/run_all_tests.sh:59` classifies a whole suite as skipped if `SKIP` appears anywhere
   in its output**, and `tests/rocblas_hipblaslt/run_test.sh:220` emits one mid-run. Latent — it
   did not fire in any run here — but any future criterion demanding `Suites skipped: 0`
   inherits it.

## Active Risks / Blockers

None outstanding for this packet.

Standing, for whoever touches this area next: changing which executable clones are dispatched
from is a change to how *every* application is instrumented, and Triton's coverage
(`tests/triton/run_test.sh`, 5 tests) remains thin for a change of that reach. It passes here,
run rather than skipped.

## Last Verified

**2026-09-08**, on `k005-005.hpcfund` (gfx90a). Full gate run: 9 passed, 1 weak, 0 judgement,
0 failed, SCOPE clean. Suite at HEAD: 10 run / 10 passed / 0 skipped / 0 failed. Suite at
`74c6ed2`: 6 run / 6 passed / 0 skipped / 0 failed. AC-9 re-measured on this architecture —
0 private code-object loads, 31 files indexed, identical to the gfx950 figures, so the mechanism
is architecture-independent as the dossier assumed rather than merely on one machine.

The source-anchor verification table from the previous session still holds; it was checked
against `74c6ed2` and the anchors have since moved with this packet's own edits.

## Proposed Spec Changes

None.

## Scope Amendments

**2026-09-08 — `inc/interceptor.h` and `.gitignore` added to the `write-scope` block.**

Reported by `ac_check_write_scope`, not noticed by hand — worth recording, because the scope
check only became readable enough to spot them once `fe66ff4` stopped `build_gfx950/` and
`build_v3.6.0_llvm/` from flooding it with 74 KB of untracked paths.

- `inc/interceptor.h` — declares the compiled `-k` regex members and `runKernelInstrumented()`.
  Its implementation lives in `src/interceptor.cc`, which was declared from the start; leaving
  the header out was an oversight in the original scope, not a widening of intent.
- `.gitignore` — the one-line `build*/` fix in `fe66ff4`. Repository-wide rather than this
  packet's deliverable, and deliberately committed on its own, but it lands inside this packet's
  commit range so the gate attributes it here. Declared rather than explained away.

Both are scope amendments under `policy/guardrails.md`: declared, logged, and reviewed after the
fact. No acceptance criterion, failure policy, or non-goal was touched.

No further amendments were needed on 2026-09-08. The closing session's edits
(`tests/run_library_filter_tests.sh`, `tests/library_filter_chain/run_test.sh`) fall inside the
already-declared `tests/` entry, and the packet's own files are allowlisted by the gate.

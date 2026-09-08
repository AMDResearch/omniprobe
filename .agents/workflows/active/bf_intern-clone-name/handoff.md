# Handoff

**Location**: `.agents/workflows/draft/bf_intern-clone-name/handoff.md`

## Current Status

Draft. The packet was filed 2026-09-08 after a pre-packet investigation that reproduced the
defect end-to-end in-repo, identified the root cause as a coordinated pair of defects, and
measured the mechanism that makes it intermittent. No production code has been changed.

The investigation went further than "confirm the framing" because the first measurement
contradicted the expected result: a straightforward `static __global__` probe **passed**. Chasing
that produced the finding that decides the shape of the fix — the defect fires on roughly 37.5%
of translation units, selected by the first character of a compiler-generated content hash, and
the other 62.5% work only because two independent bugs cancel each other out.

Consequence for whoever executes this: **a fix that makes the reported symptom go away is not
sufficient**, and the obvious regression test is a coin flip that passes while the defect is
fully present. AC-2, AC-3 and AC-5 exist for exactly this.

## Last Verified

2026-09-08, `k005-005`-class node (MI210 / gfx90a), ROCm 7.2.0, at HEAD `e5da3cd`.

- Trigger confirmed: internal linkage **and** `-fgpu-rdc`, both necessary. Anonymous namespace
  behaves as `static`.
- Instrumented clones **are** emitted for these kernels — this is a lookup defect, not a
  missing-code defect.
- End-to-end failure reproduced (`No instrumented alternative found`, letter-leading hash) and
  end-to-end accidental success reproduced (digit-leading hash), from the same source.
- 6 of 16 padding variants produced letter-leading hashes — matching the predicted 6/16.

Evidence: `.untracked/scratch/intern-probe/`. Full account in `dossier.md` § Background.

## Next Exact Step

Promote to `active` (stamping `Base Commit`), then Plan Of Record step 1: port
`.untracked/scratch/intern-probe/probe.hip` into `tests/test_kernels/` as a committed fixture and
re-confirm the failure from the in-tree copy. Do not start step 4 (the fix) before Open Question 2
is answered — see below.

## Active Risks / Blockers

- **Open Question 2 is a live risk to the chosen fix, not a curiosity.** The expected fix moves
  `Pv` inside the mangling at `src/instrumentation/InstrumentationCommon.cpp:211`, which renames
  every instrumented clone symbol. Pre-built instrumented rocBLAS and hipBLASLt libraries
  (`INSTRUMENTED_ROCBLAS_LIB_DIR`, `INSTRUMENTED_HIPBLASLT_LIB_DIR`) were built under the current
  naming, and `tests/rocblas_hipblaslt/run_test.sh:86` matches on `__amd_crk_Cijk`. Whether those
  still resolve after a pass-side rename is **unmeasured**. If they do not, the fix must be
  confined to `src/utils.cc`. Measure this before writing code.
- Write-scope overlap with the suspended `rf_exact-arch-bitcode` on
  `src/instrumentation/InstrumentationCommon.cpp`. Not a live collision — that packet is
  suspended — but the two must not execute concurrently.
- gfx90a hardware is required. On gfx950 the gfx90a `build/` tree does not error, it silently does
  not dispatch, and every assertion here would report a false green.
- `tests/run_all_tests.sh:59` marks a suite *skipped* on the substring `SKIP` anywhere in its
  output. The new test must not print that string or AC-8 misreports.

## Required Reads Before Resuming

1. This file, then `dossier.md` — especially § Background items 4 and 5, which are what make the
   acceptance criteria non-obvious.
2. `.agents/workflows/done/bf_hip-duplicate-code-object-load/dossier.md` — adjacent code paths,
   and the source of the original field report.
3. `.agents/state/current-focus.md` § Project-Level Risks — the log-line-rename hazard applies
   directly to AC-4.

## Proposed Spec Changes

None.

## Scope Amendments

None.

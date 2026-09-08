# Handoff

**Location**: `.agents/workflows/active/bf_intern-clone-name/handoff.md`

## Current Status

**Active**, promoted 2026-09-08 from `draft` after passing `workflow-readiness-check`. Base
commit `e2aa500`. The packet was filed the same day after a pre-packet investigation that
reproduced the defect end-to-end in-repo, identified the root cause as a coordinated pair of
defects, and measured the mechanism that makes it intermittent. **No production code has been
changed yet** — the gate reports 8 of 9 criteria unmet, which is the correct starting state.

The readiness check repaired three defective checks in `acceptance.sh` before promotion (AC-4,
AC-5, AC-6; one was a proven vacuous PASS). No acceptance criterion was changed. If you edit
those checks, read the dossier's Verification Strategy notes first — each is indirect on purpose
and the obvious simplification reintroduces the defect.

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

Plan Of Record step 1: port `.untracked/scratch/intern-probe/probe.hip` into
`tests/test_kernels/` as a committed fixture (name it to match `*intern*.hip`, which is what
`acceptance.sh` globs for), wire it into `tests/test_kernels/CMakeLists.txt` following the
`filter_semantics_test` entry, and re-confirm the failure from the in-tree copy on gfx90a.

Then step 2, which is a real design decision and is Open Question 1: how the test forces both
hash flavours deterministically. Note the test script must also honour `AC_FORCE_NO_INTERN=1` by
failing (AC-5), must be globbed by `tests/*intern*.sh` or `tests/*intern*/run_test.sh`, and must
not print `No instrumented alternative found` or `Found instrumented alternative` at column 0 in
its own commentary (AC-4).

**Do not start step 4 (the fix) before Open Question 2 is measured** — see below.

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

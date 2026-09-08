# Artifacts

## Produced by this workflow

| Artifact | Criterion | Status |
|---|---|---|
| `tests/test_constant_memory_visibility.sh` | AC-2, AC-3 | created |
| `tests/test_kernels/constant_memory_test.hip` | AC-2, AC-3 | created — the reproducer, brought in-repo |
| `tests/test_kernel_filter_semantics.sh` | AC-7, AC-8 | created |
| `tests/test_kernels/filter_semantics_test.hip` | AC-7, AC-8 | created |
| `tests/run_library_filter_tests.sh` | AC-4 | repaired — assertion re-pointed after the log rename |
| `tests/library_filter_chain/run_test.sh` | AC-4 | repaired — an exclusion check that could no longer fire |
| Source change in `src/utils.cc`, `inc/utils.h`, `src/interceptor.cc`, `inc/interceptor.h` | AC-2…AC-9 | landed |
| `docs/usage.md` | AC-7 | updated — see note below, the correction needed was not the one anticipated |
| `.untracked/bf_hip-dup-co/baseline-memanalysis.json`, `after-memanalysis.json` | AC-6 | captured (gfx950) |
| `.untracked/bf_hip-dup-co/adding-before.log` | AC-9 | captured (gfx950, pre-fix) |
| `.untracked/bf_hip-dup-co/adding-after.log` | AC-9 | captured (gfx90a, at HEAD) |
| `.untracked/bf_hip-dup-co/adding-after-gfx950.log` | AC-9 | the earlier gfx950 capture, kept for comparison |
| `baseline-run_all_tests.txt` | AC-4 | re-recorded on gfx90a by building the base commit |

The `-k` documentation change is worth singling out: the dossier's scope anticipated correcting
`docs/usage.md` because the implementation had diverged from it. It had not — the documentation
already described the behaviour correctly and the *implementation* was wrong, the reverse of
what was expected. What was added instead is the guarantee that was genuinely missing: filtering
no longer costs source-line attribution.

## Final gate run

`bash .agents/workflows/active/bf_hip-duplicate-code-object-load/acceptance.sh`, exit **0**, on
`k005-005.hpcfund` (MI210 / gfx90a, ROCm 7.2.0), 2026-09-08:

```
PASS  AC-1     cmake --build /work1/amd/rvanoo/repos/omniprobe/build exited 0
PASS  AC-2     __constant__ values correct inside instrumented clone, no -k argument
PASS  AC-3     __constant__ values correct when -k matches the kernel
PASS  AC-4     all suites ran and passed; nothing can have regressed against baseline-run_all_tests.txt
PASS  AC-5     Triton integration tests ran and passed
WEAK  AC-6     MemoryAnalysis output matches baseline (timestamps aside) on the sampled workload only
PASS  AC-7     -k instruments matching kernels and leaves non-matching kernels on their originals
PASS  AC-8     filtered run reports non-zero source-line attribution; no sacrificial kernel needed
PASS  AC-9     31 code objects indexed, 0 loaded into a private executable
PASS  SCOPE    no writes outside the declared write scope (7 entries; working tree and commits since 74c6ed2)

9 passed, 1 weak, 0 judgement, 0 failed
```

**No `JUDGE` lines.** AC-9 carried a `[judgement]` marker until it was amended, with user
approval, from an unpinnable "materially fewer `Adding` lines" to a pinnable "zero private
loads"; the marker was dropped at that point and the criterion is now decided outright.

### `WEAK` line, recorded rather than signed off

> `WEAK  AC-6  MemoryAnalysis output matches baseline (timestamps aside) on the sampled workload only`

AC-6 is weak **by construction**, not by shortfall: agreeing with a baseline on one workload
establishes no observable change on that workload, not absence of regression in general. Two
disclosures belong with it.

1. **The pre-change baseline was reconstructed by disabling the fix**, not captured before work
   began — plan step 2 was only partly done and the opportunity had passed. The reconstruction is
   behaviourally equivalent, and is stated as a reconstruction rather than presented as an
   original measurement.
2. **The check strips the `timestamp` field before diffing.** Every dispatch record carries
   wall-clock time, so an unnormalised diff could never pass however correct the code was, and a
   gate that cannot pass is as useless as one that cannot fail. The dossier's verification
   strategy already called for normalising this output; nothing else is filtered — kernel names,
   dispatch ids, source files, lines, columns, memory spaces and access counts are all compared
   verbatim. The two runs are otherwise byte-identical.

Both were measured on gfx950. Not re-measured on gfx90a, deliberately: it would require a fresh
pre-change baseline on this node for a criterion whose ceiling is `WEAK` either way.

### One edit to `acceptance.sh`, made after it had already passed

`workflow-complete` forbids editing the gate to make it pass. This edit did not: the gate
reported `PASS AC-4` **before** it (`/tmp/op-gate-1.log`) and after (`/tmp/op-gate-2.log`,
`/tmp/op-gate-3.log`), across three independent runs. What changed is a message that had become
false — AC-4's pass line read "(baseline had 1 pre-existing failure: Handler tests)", and the
re-recorded baseline has no failures — plus the comment block above the check, which asserted the
same. No check, threshold, or criterion text was touched.

The stricter-than-the-text discrepancy the previous session flagged for user judgement — AC-4's
implemented check demands `Suites failed: 0` while its text demands only no regression — was
**left standing**. With zero failures it never comes into play, and resolving it would be a
loosening requiring approval that nothing now needs.

## Evidence this packet was built on

Produced by the PENNANT profiling session of 2026-09-01, not by this workflow. All of it lives
outside this repository, in the PENNANT sidecar at `../pennant-amp-sidecar/`.

| Path | What it is |
|---|---|
| `pennant_omniprobe.md` | The originating write-up. §3.3 is this defect; §3.1 and §3.2 are two separate `-fgpu-rdc` problems; §6 covers the `gfx950` bitcode misselection; §7 lists recommended next steps. |
| `.untracked/omniprobe-2026-09-01/argprobe_g.hip` | **The minimal reproducer.** One kernel, a scalar and a pointer as kernargs, plus a `__constant__ double *` and a `__constant__ int` set with `hipMemcpyToSymbol`. Now brought in-repo as `tests/test_kernels/constant_memory_test.hip`, which was the condition attached to promoting this packet. |
| `.untracked/omniprobe-2026-09-01/rep1.json` | MemoryAnalysis output, single rank, `sedovsmall` at `cstop 1`, with the `-k "setBoundary"` workaround. |
| `.untracked/omniprobe-2026-09-01/rank0.json`, `rank1.json` | Same, two ranks. |
| `.untracked/omniprobe-2026-09-01/rep1.log` | Run log containing the **95 `Adding` lines**. Note this count was *not* 95 duplicate loads — `Adding` was printed for every file considered, and only some yield a code object. AC-9 was amended to measure private loads for exactly this reason. |
| `.untracked/omniprobe-2026-09-01/addr_k.csv` | Raw `AddressLogger` address trace. Contains the direct confirmation of two constant segments: the broken kernel loads its guard from `0x7fd925c1102c` while every other kernel uses `0x7fd92441102c`. |

Also produced during execution, in this repository:
`.agents/workflows/done/bf_hip-duplicate-code-object-load/pennant-rep1.log` — the end-to-end
PENNANT confirmation, energies identical to an uninstrumented run with no `-k` filter at all.

## Environments the evidence was gathered in

**Where the defect was found and fixed** — node `k007-005-v2.hpcfund`, AMD Instinct MI350X
(`gfx950`), ROCm 7.2.0, OpenMPI 4.1.8, UCX 1.18.1. Omniprobe at `74c6ed2` (2026-08-26),
VERSION 0.1.0, built into `build_gfx950/` with `-DROCM_PATH=/opt/rocm-7.2.0
-DCMAKE_HIP_ARCHITECTURES=gfx950 -DINTERCEPTOR_BUILD_TESTING=ON`. `gfx950` is not in
`docs/building-from-source.md` (which stops at gfx942) but builds and runs with no source change.

Omniprobe's own test kernels were validated first: `simple_memory_analysis_test` correctly
flagged its `strided_kernel` (4 needed → 64 used) and `bank_conflict_test` correctly reported
992 LDS conflicts in `transpose_no_pad`.

PENNANT: branch `mi300a` at `088a2a3`, plus three uncommitted build fixes and one new CMake
option — all uncommitted in that repository's working tree, and therefore not reproducible from
a clean checkout.

**Where it was closed out** — node `k005-005.hpcfund`, AMD Instinct MI210 (`gfx90a:sramecc+:xnack-`),
ROCm 7.2.0. `/work1` and `/home1` are GPFS here rather than the fuseblk of the other node, so
mmap works and the tests' compile-to-`/tmp` step is unnecessary though harmless. The `build/`
tree was rebuilt at HEAD; the base commit was built separately in a `git worktree` at
`/tmp/op-base` to re-record the suite baseline. That worktree is throwaway and node-local —
`baseline-run_all_tests.txt` carries the exact commands to recreate it.

Moving here is what made AC-4 measurable at all, and it did more than close the criterion: it
showed that two failures this packet had recorded as pre-existing code defects — the Handler
suite and the rocBLAS integration test — were artefacts of running gfx90a binaries on a gfx950
GPU. Neither exists.

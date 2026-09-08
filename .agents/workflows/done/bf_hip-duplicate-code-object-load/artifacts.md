# Artifacts

## Produced by this workflow

Nothing yet — the packet is in draft.

Planned, per the plan of record:

| Artifact | Criterion | Status |
|---|---|---|
| `tests/test_constant_memory_visibility.sh` | AC-2, AC-3 | not created |
| `tests/test_kernel_filter_semantics.sh` | AC-7, AC-8 | not created |
| `.untracked/bf_hip-dup-co/baseline-memanalysis.json` | AC-6 | not captured |
| `.untracked/bf_hip-dup-co/adding-before.log` | AC-9 | not captured |
| Source change in `src/utils.cc`, `inc/utils.h`, `src/interceptor.cc` | AC-2…AC-9 | not started |
| Doc correction for `-k` semantics | AC-7 | not started |

## Evidence this packet was built on

Produced by the PENNANT profiling session of 2026-09-01, not by this workflow. All of it lives
outside this repository, in the PENNANT sidecar at `../pennant-amp-sidecar/`.

| Path | What it is |
|---|---|
| `pennant_omniprobe.md` | The originating write-up. §3.3 is this defect; §3.1 and §3.2 are two separate `-fgpu-rdc` problems; §6 covers the `gfx950` bitcode misselection; §7 lists recommended next steps. |
| `.untracked/omniprobe-2026-09-01/argprobe_g.hip` | **The minimal reproducer.** One kernel, a scalar and a pointer as kernargs, plus a `__constant__ double *` and a `__constant__ int` set with `hipMemcpyToSymbol`. Passes on a plain run; under `omniprobe -i` the clone reads both `__constant__` values as zero while kernargs stay intact. Bring this into `tests/` as part of plan step 7. |
| `.untracked/omniprobe-2026-09-01/rep1.json` | MemoryAnalysis output, single rank, `sedovsmall` at `cstop 1`, with the `-k "setBoundary"` workaround. |
| `.untracked/omniprobe-2026-09-01/rank0.json`, `rank1.json` | Same, two ranks. |
| `.untracked/omniprobe-2026-09-01/rep1.log` | Run log containing the **95 `Adding` lines** — the baseline for AC-9. |
| `.untracked/omniprobe-2026-09-01/addr_k.csv` | Raw `AddressLogger` address trace. Contains the direct confirmation of two constant segments: the broken kernel loads its guard from `0x7fd925c1102c` while every other kernel uses `0x7fd92441102c`. |

**These artefacts are untracked and live in a different repository.** They are not guaranteed to
survive. If this packet is promoted to `active/`, copy `argprobe_g.hip` and `rep1.log` into this
repository first — the reproducer is the thing the whole packet depends on, and it currently
exists in one place, untracked.

## Environment the evidence was gathered in

- Node `k007-005-v2.hpcfund` — AMD Instinct MI350X (`gfx950`), ROCm 7.2.0, OpenMPI 4.1.8, UCX 1.18.1
- Omniprobe at `74c6ed2` (2026-08-26), VERSION 0.1.0, built into `build_gfx950/` with
  `-DROCM_PATH=/opt/rocm-7.2.0 -DCMAKE_HIP_ARCHITECTURES=gfx950 -DINTERCEPTOR_BUILD_TESTING=ON`.
  `gfx950` is not in `docs/building-from-source.md` (which stops at gfx942) but builds and runs
  with no source change.
- Omniprobe's own test kernels were validated first: `simple_memory_analysis_test` correctly
  flagged its `strided_kernel` (4 needed → 64 used) and `bank_conflict_test` correctly reported
  992 LDS conflicts in `transpose_no_pad`.
- PENNANT: branch `mi300a` at `088a2a3`, plus three uncommitted build fixes and one new CMake
  option — all uncommitted in that repository's working tree, and therefore not reproducible
  from a clean checkout.

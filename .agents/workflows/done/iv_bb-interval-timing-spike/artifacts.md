# Artifacts — iv_bb-interval-timing-spike (2026-11-08, gfx90a/MI210, ROCm 7.2.0)

Scratch (node-local): /tmp/opimpl-pn (PENNANT builds plain/bbi/bbs from ~/repos/pennant
@fix-mpi-off-boundary, aggregator handler agg/agg.cc -> per (kernel, block) CSV, analyze.py),
/tmp/opimpl-bbi (microbenchmarks k.cpp, k2.cpp, raw-dump handler).

## What landed

Pinning in `AMDGCNSubmitBBInterval.cpp`: `llvm.amdgcn.sched.barrier(0)` after the start clock and
before the stop clock, and an empty side-effecting inline-asm ("v") use, before the stop clock,
of every value the block defines for later blocks or PHIs (ints widened/split to 32/64 bits,
pointers via ptrtoint, floats bitcast, vectors per element). Both plugin variants.

## Microbenchmark (one wave)

- Loop body (if/else + FMA): 60 ticks/iteration, steady at 10 / 1000 / 100000 iterations
  (first iteration ~520, cold). Fix A alone (no pinning): ~4 (subagent) / 12 (suite 22) ticks.
- Single-block FMA chain K=16/256/1024/4096: 4428 / 13832 / 54476 / 162052 ticks — monotone;
  ~35 ticks per FMA at large K [inf: instruction fetch of straight-line code run once].
- Smallest block: 16 ticks.

## PENNANT sedovsmall

- Overhead: hydro cycle time 0.75 ms plain; 1.27 ms plain under omniprobe (timing mode);
  2.69 s BBInterval-instrumented; 2.77 s BBStart-instrumented. So the run-level slowdown
  (~2000x) is omniprobe's instrumented-mode per-dispatch path, the same for BBStart; it is not
  specific to BBInterval. All 3 BBInterval runs exit 0.
- Kernel time shares, plain (omniprobe timing mode): gpuMain2<4> 44.6%, gpuMain5 16.8%,
  gpuMain3_interior 14.5%, gpuMain4<4> 13.2%.
  Summed per-wave block ticks (runs 1/2/3): gpuMain5 86.6/85.4/86.8%, rocprim sort ~10-11%,
  gpuMain2 1.5/1.7/1.7%, gpuMain4 0.6%, gpuMain3 0.5%. Not comparable as kernel time (waves run
  in parallel), and badly implausible as cost.
- Within-kernel ranking, runs 1/2/3 (share of the kernel's ticks):
  - gpuMain5: identical ranking; top block 94.8/94.7/94.6% (median ~330k ticks/wave). gpuMain5
    has `__syncthreads()` and an `atomicMin` on double (CAS loop): this is waiting, inflated by
    the other waves' instrumentation [inf].
  - gpuMain4<4>: identical ranking; top 55.3/55.6/56.0%.
  - gpuMain2<4>: top two stable (57-62%, 22-26%); ranks 3-4 swap (6.2/5.3/5.9 vs 4.9/4.5/6.5).
  - gpuMain3_interior: top stable (24.7-26.7%); ranks 2-3 swap (12.7-14.9% each).
- Floor: smallest per-block minimum in PENNANT 528 ticks (every block). Blocks run once or a
  few times per wave, so cold instruction fetch of the instrumented code dominates (the
  microbenchmark's first iteration also costs ~520) [inf].
- Line attribution: block lines come from the block's first instruction and are often inlined
  from a header (e.g. gpuMain5's hot block reported line 691, gpuMain5 is at HydroGPU.cc:736).

## Verdict

Relative ranking is stable for the top block, but the numbers are dominated by artifacts on
exactly the kind of code IntelliKit is meant to analyze. A timing analyzer would mislead. (c).

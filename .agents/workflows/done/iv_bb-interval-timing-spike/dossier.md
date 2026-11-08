# Dossier — iv_bb-interval-timing-spike

## Metadata

- Workflow ID: iv_bb-interval-timing-spike
- Workflow Type: investigation (time-boxed spike, supervisor ruling (b), 2026-11-08)
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Base Commit: 4a52d2f

```write-scope
src/instrumentation/AMDGCNSubmitBBInterval.cpp
tests/test_bb_interval.sh
docs/hip-instrumentation.md
```

## Question

Can BBInterval give per-block timing trustworthy enough to report to IntelliKit (owner: "if you can
get it to work, update IntelliKit with the plugin info, and see if IntelliKit would use it")?
Measure on a microbenchmark and on PENNANT (sedovsmall, gfx90a, -O3, MPI off): overhead,
stability and plausibility of the per-block ranking in the hot kernels, the tick floor.

## Answer: no, for codes like PENNANT -> outcome (c)

Pinning (landed) makes a block's interval contain the block's work. But on PENNANT the per-block
numbers measure the instrumentation more than the code (cold instruction fetch of ~1000 inlined
instructions per block; barrier/atomic waits inflated by the other waves' instrumentation), so
they would mislead an agent. No timing analyzer. BBInterval is documented as experimental;
IntelliKit should use BasicBlockAnalysis counts. Evidence in artifacts.md.

## Acceptance Criteria (of what landed)

- **AC-1**: suite 22 test 4: ticks per loop iteration >= 30 (measured 60, stable); without
  pinning 12 -> FAIL.
- **AC-2**: full suite passes.

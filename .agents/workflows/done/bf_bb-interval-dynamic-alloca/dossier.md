# Dossier — bf_bb-interval-dynamic-alloca

## Metadata

- Workflow ID: bf_bb-interval-dynamic-alloca
- Workflow Type: bugfix
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Base Commit: 8fec61e

```write-scope
src/instrumentation/AMDGCNSubmitBBInterval.cpp
src/time_interval_handler.cc
tests/test_kernels/bb_interval_loop_test.cpp
tests/test_kernels/CMakeLists.txt
tests/test_bb_interval.sh
tests/run_all_tests.sh
```

## Objective

A BBInterval-instrumented kernel with a loop runs to completion and reports real intervals.
First step of the owner's "real per-block timing via BBInterval" item; the rest needs a decision
(see artifacts.md).

## Background (survey 2026-11-03 § I defect 3, root cause found 2026-11-08 by a sub-investigation)

`AMDGCNSubmitBBInterval.cpp` created its `[2 x i64]` timestamp buffer with an `alloca` in every
basic block. Outside the entry block an alloca is dynamic (`.uses_dynamic_stack: true`): the stack
pointer grew 16 B/lane every time a block ran, never restored, and the ROCm 7.2 codegen stored the
slot with a wave-scaled `soffset` but reloaded it with an unscaled per-lane `offen` VGPR offset
(read from the ISA). Result: every interval except the entry block's read start=stop=0, and from
17 loop iterations the kernel raised "illegal memory access" (measured: 16 pass, 17..100000 fault).
The "inconsistent offsets" is inferred to be an LLVM codegen bug; the plugin should not create
dynamic allocas regardless.

Fix: one alloca in the entry block, reused by every block (excluded when picking the entry
block's first instruction, else the module fails verification). Also `time_interval_handler`'s
`clear()` reset `first_start_` to 0 instead of the constructors' all-ones sentinel.

## Acceptance Criteria

- **AC-1**: suite 22: at 10 and 1000 iterations exit 0 with a non-zero first start, and intervals =
  trip count + a constant. Unfixed: first start 0 at 10; exit 3 (GPU fault) at 1000; 3/3 FAIL.
- **AC-2**: full suite passes, 0 skipped.

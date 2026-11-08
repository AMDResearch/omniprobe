# Dossier — bf_faulted-dispatch-hang

## Metadata

- Workflow ID: bf_faulted-dispatch-hang
- Workflow Type: bugfix
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Base Commit: 1434fa1

```write-scope
src/interceptor.cc
inc/interceptor.h
tests/test_kernels/fault_test.cpp
tests/test_kernels/CMakeLists.txt
tests/test_faulted_dispatch.sh
tests/run_all_tests.sh
```

## Objective

An application whose kernel faults on the GPU exits under omniprobe within seconds, with the
application's own (non-zero) exit status and a message naming the dispatch that never completed,
instead of hanging forever at exit.

## Background

Survey 2026-11-03 § I defect 3. Reproduced 2026-11-08 on gfx90a: a kernel storing to an unmapped
address. Bare: `sync: an illegal memory access was encountered`, exit 3, 0.24 s. Under
`omniprobe -- ./fault` (no `-i`): still running at 60 s; "Comms Runner" and "Cache Watcher"
shut down, "signal_runner is shutting down" never printed. Mechanism (read):
`signal_runner` (`src/interceptor.cc:586-613`) loops `do { wait each pending signal } while
(getPendingSignals())` without checking `shuttingdown()`; a faulted dispatch's completion signal
never reaches 0, so the loop never ends and `~hsaInterceptor`'s `signal_runner_.join()` blocks.

Fix: after shutdown starts, keep completing pending dispatches, but once none has completed for a
grace period (3 s), abandon the rest with a warning naming each kernel. Abandoned dispatches are
not reported (their message buffers may hold a partially written message) and their comms objects
are deliberately leaked (the process is exiting). Root-causing the BBInterval fault itself is
out of scope (separate investigation).

## Acceptance Criteria

- **AC-1**: `omniprobe -- fault_test` (timing mode) exits within 30 s with the application's
  status (3), printing a warning that names `fault_kernel`. Fails on the unfixed build (timeout).
- **AC-2**: same with `-i -a AddressLogger` (instrumented clone faults; comms object abandoned).
- **AC-3**: a normal run's shutdown is not slowed: `fault_test --no-fault` under omniprobe exits
  0 with no abandonment warning.
- **AC-4**: full suite passes, 0 skipped; `run_module_load_tests.sh` passes (interceptor changed).

Also in scope (found while reading): `getPendingSignals` took no lock (`lock(mutex)` declared a
function). Fixed; no test (data race, not reproduced).

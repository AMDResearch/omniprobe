# Dossier — bf_bba-hardening

## Metadata

- Workflow ID: bf_bba-hardening
- Workflow Type: bugfix
- Lifecycle State: active
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Intended Write Scope: see the `write-scope` block below (canonical)
- Dependencies On Other Active Workflows: appends one `run_suite` line to `tests/run_all_tests.sh`
- Base Commit: c2dd8404da4f344a4262a093dea6f2b5a03c4e58

```write-scope
src/basic_block_analysis.cc
inc/basic_block_analysis.h
src/message_logger.cc
omniprobe/omniprobe
omniprobe/config/analytics.py
tests/test_bba_robustness.sh
tests/run_all_tests.sh
```

## Objective

BasicBlockAnalysis (BBA) never crashes on input it cannot interpret, says so, and — scope still
to be decided (phase 2) — reports block identity, source attribution and timing that mean what
they claim, with the semantics documented for IntelliKit.

## Background / Context

Sub-items assigned by the supervisor 2026-11-08: (a) segfault on AddressMessages binaries +
no analyzer/plugin check (survey 2026-11-03 § I defects 5, 6); (b) segfault on Pennant
`gpuMain3_interior` (pnimpl; BBStart, non-RDC); (c) implausible BBA numbers (ikimpl: p50 4–23 M
cycles, block 0 at line 0); (d) BasicBlockLogger `-t csv -l f` writes the AddressLogger CSV
header then JSON rows.

### Diagnosis (code read by subagent, file:line; measurements by me)

- **Identity mismatch.** BBStart emits `user_type=2, user_data=<IR block ordinal in layout order>`
  (`src/instrumentation/AMDGCNSubmitBBStart.cpp:66-135`). BBA uses user_data as an index into
  kernelDB's block list, which is built from **ISA disassembly** with different split rules
  (`external/kerneldb/src/kernelDB.cc:661-835`; split at branches, branch dropped, `s_endpgm`
  alone, `s_branch` targets not split). Nothing maps one to the other. Measured: Pennant
  `gpuMain3_interior` sends index 7 with 4 kernelDB blocks — the crash in (b).
- **No type check, assert-only bounds check** (`basic_block_analysis.cc:269-284` at base): address
  messages (user_data = `rw | space<<2 | size<<6`) used as block indices — the crash in (a).
- **Unstable IDs.** `basic_block_id` in JSON is a counter over a map keyed by `basicBlock*`
  (pointer order). Measured: two identical runs of the same binary list blocks in different
  orders (block 0 = line 17 in one, line 0 in the other).
- **Timing.** Duration = `hdr.timestamp` delta between consecutive BBStart messages of one wave;
  timestamp is `__clock64()` = `s_memtime` (shader-clock cycles) taken at the start of the
  submit (`external/dh_comms/include/dh_comms_dev.h:132`). The interval includes the rest of the
  submit: spinning for the shared sub-buffer, and waiting for the host to drain a full buffer.
  Measured on ikimpl's kernel: 4096 waves → p50 4–24 M cycles; same kernel, 16 waves → p50
  25–60 k. Durations are dominated by instrumentation contention and scale with grid size. Also:
  exec mask attributed to the wrong block; last block of each wave never timed; the loop block
  reports 0.
- BBInterval (in-block `s_clock64` pair, `AMDGCNSubmitBBInterval.cpp:91-169`) measures the block
  without the submit, but BBA ignores its messages (was `assert(false)`), and BBInterval binaries
  fault on large loop kernels (survey defect 3, `bf_faulted-dispatch-hang`).
- **(d)** `message_logger_t` writes the CSV header unless json (`message_logger.cc:47-54`) but
  only address messages have a CSV row; type 2 falls to `default`, which writes JSON (`:72-75`).
- **Analyzer/plugin check.** `analytics.py` names a plugin per analyzer, but it is used only for
  Triton (`LLVM_PASS_PLUGIN_PATH`); nothing checks a HIP binary's instrumentation.

## Acceptance Criteria

Phase 1 (done):
- **AC-1** (a): BBA on `dual_kernel_test` (AddressMessages) exits 0, warns once that it needs a
  BBStart binary, JSON parses. Fails on the unfixed build (rc 139). Suite 14 test 1.
- **AC-2**: BBA on `dual_kernel_bbstart_test` still exits 0 with no warning. Suite 14 test 2.
- **AC-3** (b, manual — Pennant is outside this repo): the supervisor's Pennant command exits 0
  and warns "block index 7 out of range … (4 blocks known)". Unfixed: rc 139.
- **AC-4**: full suite passes.

Phase 2 (pending decision — see handoff): (c) semantics, (d) logger CSV, analyzer/plugin check.

## Non-Goals

BBInterval device fault (`bf_faulted-dispatch-hang`).

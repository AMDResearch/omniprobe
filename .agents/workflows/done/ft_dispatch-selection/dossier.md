# Dossier: ft_dispatch-selection

## Metadata

- Workflow ID: ft_dispatch-selection
- Workflow Type: feature
- Lifecycle State: done
- Owner / Current Executor: opdisp (worker), supervised
- Intended Write Scope:
- Dependencies On Other Active Workflows: none active. Overlaps `rf_rename-logduration-to-omniprobe`
  (suspended) on the `LOGDUR_DISPATCHES` name, which this packet keeps.
- Base Commit: e866d24

```write-scope
omniprobe/omniprobe
omniprobe/api/
src/utils.cc
inc/utils.h
src/interceptor.cc
inc/interceptor.h
src/dispatch_spec.cc
inc/dispatch_spec.h
src/CMakeLists.txt
CMakeLists.txt
src/comms_mgr.cc
inc/comms_mgr.h
src/message_logger.cc
inc/message_logger.h
src/basic_block_analysis.cc
inc/basic_block_analysis.h
src/memory_heatmap.cc
src/time_interval_handler.cc
src/time_interval_handler_wrapper.cc
inc/time_interval_handler_wrapper.h
src/memory_analysis_handler.cc   # constructor and JSON header line only; LDS model is oplds's
src/pyHandler.cc
inc/pyHandler.h
inc/memory_analysis_handler.h    # one member only
inc/memory_heatmap.h
inc/time_interval_handler.h
inc/kernel_dispatch.h
tests/
docs/
README.md
```

## Objective

Replace `-d all|1|random` with dispatch selection by per-kernel dispatch number — lists, inclusive
ranges and repeat shorthands — combined with the existing `-k` regex so that numbers count per
matching kernel; remove `-d random`. Source: Rene, `rene-response-2026-11-09.md` § Omniprobe.

## Background / Context

Survey of the current code paths, semantics, syntax options and recommendations:
[design.md](design.md). Phase 1 (this draft) is design only; the supervisor rules on the options
in design.md § 5 before any code is written.

## Ruling (supervisor, 2026-11-09)

Option A. Q2 1-based; Q3 inclusive `a-b`, no half-open; Q4 open-ended `a-` kept; Q5 per demangled
name per process, all GPUs share one count (document the `-d 1` multi-GPU change and the
non-determinism under concurrent submission; no per-GPU flag); Q6 add `kernel_dispatch` to
JSON/CSV/stderr, keep the global `dispatch_id`; Q7 every dispatch of the kernel counts; Q8 count =
total copies incl. the first; Q9 remove `random`, error points to `-d 1::100`; Q10 accepted.
Additional rules: no `-k` ⇒ every kernel has its own counter; `-d all` stays default; whitespace
inside a spec is an error; docs show brackets only quoted and mention the unquoted-glob trap; the
uninitialised-flag defect for unknown `-d` values gets a criterion that fails on the current tree.

## Contract

- **Grammar** (design.md § 3, Option A): `all` | `pattern[:count[:stride]]`, optionally inside
  `[...]`; `pattern := item{,item}`; `item := N | N-N | N-`; numbers 1-based, ≤ 2^63−1.
  Semantics in design.md § 2.3; an open range cannot be repeated (`count` must be absent or 1).
- **Two parsers, one table.** `omniprobe/api/dispatch_spec.py` (launcher and Python API) and
  `src/dispatch_spec.cc` (runtime) implement the same grammar with the same error reasons;
  `tests/dispatch_spec_cases.txt` is the single source of expected results for both.
- **Launcher** validates `-d` before starting the application; invalid → message, exit 2.
  It exports the spec (brackets stripped) as `LOGDUR_DISPATCHES`.
- **Runtime** never reads an unrecognised value as anything: invalid `LOGDUR_DISPATCHES` →
  `omniprobe: ERROR:` at startup and in the exit summary, and no dispatch is instrumented.
- **Counting**: per demangled kernel name per process; every dispatch of a known kernel object
  counts, whether instrumented or not and whether a clone exists yet.
- **Output**: `kernel_dispatch` (per-kernel ordinal) next to `dispatch_id` in every built-in
  handler's JSON, in both logger CSV row kinds (column after `dispatch`), in the PythonHandler
  dicts, and on the stderr `Found instrumented alternative` line. `dispatch_id` is unchanged.
  The plugin ABI (`getMessageHandlers(kernel, dispatch_id, …)`) is unchanged.
- `-d random`, `randomDispatcher`, `RANDOM_DISPATCH_DISTRIBUTION` and suite 27 are removed.

## Acceptance Criteria

All are decided by `tests/test_dispatch_selection.sh` (named checks) unless stated. Each fails on
the tree at the base commit, where neither parser, the test app nor the field exists.

- **AC-1**: every case in `tests/dispatch_spec_cases.txt` gives the expected result through the
  Python parser — membership in 1..300 for valid specs, the expected error reason for invalid
  ones. The table holds all five of Rene's examples, the ruling's whitespace rule, `random`, and
  each error class of design.md § 4.
- **AC-2**: the same table, same results, through the C++ parser (`dispatch_spec_check` binary).
- **AC-3**: `omniprobe -i -d <bad>` exits 2 with the reason and does not start the application,
  for `5x`, `0`, `1, 2` (whitespace) and `random` (whose message names `-d 1::100`).
- **AC-4** (uninitialised-flag defect): with `LOGDUR_DISPATCHES=5x` set directly in the
  environment (launcher bypassed), the run prints `invalid dispatch spec` and instruments no
  dispatch. On the base tree the value leaves the three dispatch flags indeterminate and prints
  nothing.
- **AC-5**: on a test app that launches `kernel_a` and `kernel_b` alternately 12 times each, the
  set of (kernel, `kernel_dispatch`) pairs in MemoryAnalysis JSON equals the expected set exactly
  for: `all`, `1`, `2,5`, `-k kernel_a -d 2,5`, `1,3,4:3`, `1,3:2:6`, `1::5`, `10-`, `[2-4]`.
- **AC-6**: `kernel_dispatch` is present and correct (= 2 with `-d 2`, while `dispatch_id` is the
  global id, ≠ 2) in Heatmap, MemoryAnalysis, AddressLogger JSON, AddressLogger CSV (header column
  `kernel_dispatch` after `dispatch`), and the stderr `Found instrumented alternative` line.
  BasicBlockAnalysis/BasicBlockLogger and PythonHandler carry it too (checked in their suites).
- **AC-7**: Python API: `Omniprobe().analyze_memory(app, dispatches="2,5")` returns exactly the
  2nd and 5th dispatch of each kernel with `kernel_dispatch` set; `dispatches="random"` raises
  `ValueError` without starting the application.
- **AC-8**: the suite is registered in `tests/run_all_tests.sh` and suite 27 (`-d random`) is gone;
  the full suite passes on this node with only the rocBLAS/hipBLASLt suites (3–5) skipped as N/A
  on gfx950.
- **AC-9** `[WEAK: text presence]`: `docs/usage.md` documents the grammar, shows brackets only
  inside quotes, mentions the glob trap, the multi-GPU `-d 1` change and non-determinism under
  concurrent submission; `random` appears in no doc or help text except as "removed".

## Failure Policy

Stop and report if the counting point cannot be moved without changing which dispatches run
uninstrumented today under `-d all`, or if `src/memory_analysis_handler.cc` needs more than a
constructor/JSON-header edit (that file's LDS code is oplds's).

## Scope

Launcher, Python API, runtime selection, built-in handler output, tests, docs.

## Non-Goals

Rank/device selection; renaming `LOGDUR_*`; IntelliKit changes (ikl, relayed); the LDS model.

## Verification Strategy

`acceptance.sh` runs `tests/test_dispatch_selection.sh` and the full suite; AC-9 is greps
(reported WEAK). Fails-before evidence: the new test run against the base build, recorded in
artifacts.md.

## Open Questions

None; ruled 2026-11-09.

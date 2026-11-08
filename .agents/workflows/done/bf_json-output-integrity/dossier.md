# Dossier — bf_json-output-integrity

## Metadata

- Workflow ID: bf_json-output-integrity
- Workflow Type: bugfix
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Intended Write Scope: see the `write-scope` block below (canonical)
- Dependencies On Other Active Workflows: appends one `run_suite` line to `tests/run_all_tests.sh`
  (shared, append-only, with `bf_pyhandler-gil` and `bf_intern-clone-name`; the classifier edit in
  `bf_library-filter-chain-silent-pass` is unaffected)
- Base Commit: ba5c79bc07ccc659e5911764afe3b58f38f819b0

```write-scope
inc/json_output.h
src/memory_analysis_handler.cc
src/basic_block_analysis.cc
omniprobe/omniprobe
tests/test_json_output.sh
tests/test_kernels/CMakeLists.txt
tests/run_all_tests.sh
```

## Objective

Every `-t json -o FILE` that omniprobe writes is a file `json.load` accepts, whatever the number
of dispatches, whichever kernels `-k` lets through, and however many times the same file was used
before. A `-o`/`-l` file holds the output of one run only.

## Background / Context

Filed from the 2026-11-03 survey, section I (defects 1, 2, 4), cross-checking reports from the
IntelliKit worker, whose basic-block and filtered-memory paths are blocked by them. All three exit
0 and leave a file that does not parse:

1. **BasicBlockAnalysis, more than one dispatch.** `basic_block_analysis::report_json`
   (`src/basic_block_analysis.cc:455-460` at base) wrote a bare `{...}` per dispatch with no `[`
   or `,`; the CLI finalizer only wraps/terminates, giving `[ {..} {..} ]`.
2. **MemoryAnalysis, `-k` excluding the first dispatch.** `report_json`
   (`src/memory_analysis_handler.cc:789-803` at base) chose `[` vs `,` by `dispatch_id_ == 1`.
   Dispatch ids come from a process-wide counter that counts every dispatch packet
   (`src/interceptor.cc:892`), including those `-k`/`-d` keep from the handler, so the file began
   with `,` and the finalizer (handles only `[` / `{` starts) left it broken.
3. **`-o`/`-l` appends across runs.** Every handler opens its output with `std::ios::app`
   (`memory_analysis_handler.cc:632`, `basic_block_analysis.cc:346`, `memory_heatmap.cc:79`,
   `message_logger.cc:43`, `time_interval_handler.cc:96`, `utils.cc:863/873/915`), which is
   needed within a run (new handler objects per dispatch, `comms_mgr.cc:54-102`), and nothing
   truncated the file at the start of a run.

Heatmap and AddressLogger write JSON Lines (one object per line), not an array, and are not in
the finalizer's handler list; they were affected by defect 3 only. TimeInterval writes no JSON.

## Contract

The array format of MemoryAnalysis/BasicBlockAnalysis JSON and the JSON Lines format of
Heatmap/AddressLogger are unchanged. Console output is unchanged. New: a `-o`/`-l` file is
overwritten by a run (documented in `--help`).

## Acceptance Criteria

All checked by `tests/test_json_output.sh` (suite 12 of `run_all_tests.sh`), which parses every
file with Python's `json` module and counts entries — never by grepping for brackets.
Binaries: `dual_kernel_test` (AddressMessages) and the new `dual_kernel_bbstart_test`
(same source, BBStart plugin; BasicBlockAnalysis needs block-index messages).

- **AC-1** (defect 1): BasicBlockAnalysis over two kernels gives a JSON list of 2 entries (T5).
- **AC-2** (defect 2): MemoryAnalysis with `-k kernel_beta` gives a list of 1 entry for
  `kernel_beta` (T2); BasicBlockAnalysis likewise (T6).
- **AC-3** (defect 3): two consecutive runs to the same `-o` give the same entry/line count as one
  run, for MemoryAnalysis (T3), BasicBlockAnalysis (T7), Heatmap (T10), AddressLogger (T13), and
  CSV via `-l` (T14); a pre-existing non-JSON file is replaced (T4).
- **AC-4** (baselines, must keep passing): MemoryAnalysis unfiltered (T1); Heatmap and
  AddressLogger lines each parse, unfiltered and filtered (T8, T9, T11, T12).
- **AC-5**: full `tests/run_all_tests.sh` on gfx90a: all suites run pass, 0 skipped, 0 failed.

AC-1..AC-3 fail on the unfixed build (T2-T5, T7, T10, T13, T14); see `artifacts.md`.

## Failure Policy

`stop` — report rather than apply a speculative fix.

## Scope

The two array writers' separator logic, run-start truncation in the CLI, a parse check in the CLI
finalizer (warning only), the regression suite and its BBStart test binary.

## Non-Goals

- BasicBlockAnalysis segfault on AddressMessages binaries and analyzer/plugin mismatch
  (`bf_bba-hardening`); faulted-dispatch hang (`bf_faulted-dispatch-hang`).
- Changing Heatmap/AddressLogger from JSON Lines to an array.
- Targets that fork several instrumented processes writing one file (each process's first write
  would see a non-empty file only if another already wrote; not tested), and direct
  `LD_PRELOAD` use without the CLI (no truncation, no closing `]` — the CLI owns both).
- AddressLogger in CSV mode also emits JSON lines per message (`message_logger.cc:71`); noted,
  not changed.

## Plan Of Record

1. Reproduce with a behavioural test that parses the output (done: 9 of 14 checks fail).
2. Separator from file state: `json_array_separator()` in `inc/json_output.h` — `[` if the
   output file is empty, `,` otherwise. Used by both array writers. File state rather than
   per-process or per-handler state: handlers are per dispatch, dispatch ids count filtered
   dispatches, and reports are serialized under `comms_mgr::mutex_`.
3. CLI truncates the `-o`/`-l` file once, before the target starts.
4. Finalizer warns if the finished array does not parse.
5. Add the suite to `run_all_tests.sh`; full suite.

## Verification Strategy

Pre-fix and post-fix runs of `tests/test_json_output.sh` on gfx90a; full suite post-fix;
`tests/test_python_api.py` (unit, 10 tests).

## References

- `.untracked/survey-2026-11-03/report.md` § I, `I-repro-json.md` (untracked survey scratch).

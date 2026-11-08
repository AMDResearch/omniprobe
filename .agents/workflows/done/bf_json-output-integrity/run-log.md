# Run-Log

## Log Entries

### 2026-11-08 — created, reproduced, fixed, verified (one session)

- Inventory of every output writer (subagent, file:line in dossier § Background): five handlers
  plus logDuration open in append mode; only MemoryAnalysis and BasicBlockAnalysis write arrays.
- Added `dual_kernel_bbstart_test` and `tests/test_json_output.sh`; on the unfixed build 9 of 14
  checks fail, exactly the AC-1..AC-3 set except T6 (artifacts.md).
- Fix: `json_array_separator()` (file-state separator) in both array writers; CLI truncates the
  output file before the run; finalizer warns when the array does not parse.
- First rebuild failed to compile (removed local still used for the console newline); fixed.
- Post-fix: new suite 14/14; full suite 12/12, 0 skipped; Python API unit tests 10/10.

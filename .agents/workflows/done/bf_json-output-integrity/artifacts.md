# Artifacts — bf_json-output-integrity

## Pre-fix — 2026-11-08, gfx90a (MI210), ROCm 7.2.0, build/ at ba5c79b (code = 64cc406), test script added, no fix

```
T1 memory_analysis_two_kernels	PASS - OK 2 entries
T2 memory_analysis_first_kernel_filtered_out	FAIL - BAD does not parse: Expecting value: line 1 column 1 (char 0)
T3 memory_analysis_second_run_replaces_file	FAIL - BAD does not parse: Extra data: line 60 column 2 (char 1445)
T4 memory_analysis_preexisting_file_replaced	FAIL - BAD does not parse: Expecting value: line 1 column 1 (char 0)
T5 basic_block_analysis_two_kernels	FAIL - BAD does not parse: Expecting ',' delimiter: line 36 column 1 (char 851)
T6 basic_block_analysis_first_kernel_filtered_out	PASS - OK 1 entries
T7 basic_block_analysis_second_run_replaces_file	FAIL - BAD does not parse: Expecting ',' delimiter: line 36 column 1 (char 851)
T8 heatmap_two_kernels_json_lines	PASS - OK 2 lines
T9 heatmap_first_kernel_filtered_out_json_lines	PASS - OK 1 lines
T10 heatmap_second_run_replaces_file	FAIL - BAD 4 lines, expected 2
T11 addresslogger_two_kernels_json_lines	PASS - OK 16 lines
T12 addresslogger_first_kernel_filtered_out_json_lines	PASS - OK 8 lines
T13 addresslogger_second_run_replaces_file	FAIL - BAD 32 lines, expected 16
T14 csv_log_location_second_run_replaces_file	FAIL - 34 lines after one run, 68 after two
```

9 FAIL: T2-T5, T7, T10, T13, T14 — every AC-1..AC-3 check except T6. T6 (BBA, `-k` excluding
the first kernel) passed before the fix because the finalizer wraps a single bare object; it is
kept as a guard. T7 fails pre-fix on defect 1 as well as 3; T3/T10/T13/T14 isolate defect 3.

## Post-fix

- `tests/test_json_output.sh`: 14/14 PASS.
- `tests/run_all_tests.sh`: Suites run 12, passed 12, skipped 0, failed 0 (rc 0).
- `python3 -m pytest tests/test_python_api.py`: 10 passed.

## Produced

- `inc/json_output.h` (new), `tests/test_json_output.sh` (new), `dual_kernel_bbstart_test` target.

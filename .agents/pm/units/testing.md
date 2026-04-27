# Testing

## Purpose

Verifies correct behavior of message handlers and the full omniprobe instrumentation
pipeline. Currently uses end-to-end tests through the omniprobe CLI; unit tests with
GoogleTest are planned but disabled.

## Current Truth

**Test runner:** `tests/run_handler_tests.sh` (modular structure with subscripts).

**Tests:** 25 handler tests (6 basic, 6 block filter, 3 library filter, 7 scope filter, 3 module-load).

**Additional suites:**
- Library filter chain (5 tests)
- Triton (5 tests, requires `TRITON_DIR`)
- rocBLAS (5 tests, requires `INSTRUMENTED_ROCBLAS_LIB_DIR`)
- hipBLASLt (5 tests, requires `INSTRUMENTED_HIPBLASLT_LIB_DIR`)
- Combined rocBLAS+hipBLASLt

**Top-level runner:** `tests/run_all_tests.sh` (runs all 6 suites).

**Test helpers:**
- `run_test "test_name" "/path/to/kernel" "AnalyzerName" "expected pattern"`
- `run_filter_test "test_name" "/path/to/kernel" expected_count "x_filter" "y_filter" "z_filter"`
- `run_library_filter_test "test_name" "/path/to/kernel" '{"exclude":[...]}' "present|absent" "pattern"`

**GoogleTest:** Integration prepared but disabled (`INTERCEPTOR_BUILD_TESTING=OFF`).

**Test kernels** in `tests/test_kernels/`:
- `simple_heatmap_test.cpp`
- `simple_memory_analysis_test.cpp`
- `bank_conflict_test.cpp`
- `scope_filter_test.cpp`
- `module_load_kernel.hip` + `module_load_test.cpp`
- `hip_test_utils.h`

## Boundaries and Dependencies

- Working omniprobe installation.
- Instrumented test kernels.
- ROCm/HIP runtime.
- Available GPU device (device 0).

## Anchors / References

- `tests/run_all_tests.sh`
- `tests/run_handler_tests.sh`
- `tests/test_kernels/CMakeLists.txt`

## Negative Knowledge

- **Do NOT attempt to use GoogleTest** until handler refactoring for dependency injection is complete.
- Test kernels **MUST** be compiled with `-g` (debug info). Without it, DWARF source location info is missing, causing `MemoryAnalysis` handler to silently drop all messages.
- Test kernels should read back results (`hipMemcpy` to host) to prevent dead-store elimination.
- Library filter chain test 2 hangs; tests 4-5 previously failed. rocBLAS integration needs investigation.

## Open Questions

- What refactoring is needed to enable true unit tests with GoogleTest?
- Should we create a test fixture library for handler testing?

## Related Workflows

- `rf_lazy-kerneldb-loading` (may affect test infrastructure)

## Last Verified

2026-04-09

# Verification Policy

Verification is any concrete check that increases confidence in the result, such as tests,
builds, linters, focused manual inspection, or structured document validation.

## Required

- Run verification after meaningful implementation phases when the project affords it.
- Record what was run, what passed, and what remains unverified.

## Reporting

- Put workflow-phase verification in `run-log.md`.
- Put session-level verification in a session capture when no workflow packet exists.

## Omniprobe-Specific Verification

### Build verification
```bash
cd build && ninja
```
After any code change, confirm the project still builds cleanly before proceeding.

### End-to-end test suites
Primary test runner (all suites):
```bash
./tests/run_all_tests.sh
```

Individual suites:
- `./tests/run_handler_tests.sh` — 25 handler tests (basic, block filter, library filter, scope filter, module-load)
- `./tests/library_filter_chain/run_test.sh` — library include/exclude with dependency chains
- `TRITON_DIR=/path/to/triton ./tests/triton/run_test.sh` — Triton integration (5 tests, skips if env unset)
- `INSTRUMENTED_ROCBLAS_LIB_DIR=/path ./tests/rocblas_filter/run_test.sh` — rocBLAS integration (skips if env unset)
- `INSTRUMENTED_HIPBLASLT_LIB_DIR=/path ./tests/hipblaslt/run_test.sh` — hipBLASLt integration (skips if env unset)

### Requirements
- Tests must run on real GPU hardware (device 0 via `ROCR_VISIBLE_DEVICES=0`)
- Test kernels must be compiled with `-g` (debug info) for DWARF-based analysis
- GoogleTest is present but disabled (`INTERCEPTOR_BUILD_TESTING=OFF`) — do not enable without refactoring handlers for dependency injection

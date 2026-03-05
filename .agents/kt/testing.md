# Testing Infrastructure

## Responsibility
Verifies correct behavior of message handlers and the full omniprobe instrumentation pipeline. Currently uses end-to-end tests through the omniprobe CLI; unit tests with GoogleTest are planned for future implementation.

## Core Concepts

- **End-to-end tests**: Tests that run complete instrumented kernels through omniprobe, verifying handler output
- **Test kernels**: Simple HIP kernels in `tests/test_kernels/` that emit specific message patterns
- **Handler validation**: Verifying that handlers correctly process messages and produce expected reports
- **Integration testing**: Testing the full pipeline: instrumentation → dispatch → message handling → reporting

## Current Testing Approach

### Why End-to-End via Omniprobe?

The current codebase structure makes traditional unit testing difficult:

1. **Handler coupling**: Message handlers require:
   - Active `dh_comms` instance with GPU buffers
   - Running GPU kernels to generate messages
   - kernelDB loaded with kernel metadata
   - Complete HSA runtime environment

2. **No dependency injection**: Handlers are tightly coupled to:
   - Global state in `comms_mgr` pool
   - HSA runtime initialization
   - GPU device context
   - Complex initialization sequences

3. **Infrastructure requirements**: Testing handlers in isolation would require:
   - Mocking GPU message buffers
   - Mocking kernelDB queries
   - Mocking HSA runtime
   - Significant refactoring for testability

4. **Proven infrastructure**: Omniprobe provides:
   - Known-good instrumented kernels
   - Complete runtime environment
   - Real GPU execution
   - Observable handler output

**Decision**: Use end-to-end tests now; refactor for unit testability later.

### Future Unit Testing Strategy

GoogleTest integration is prepared but currently disabled (`INTERCEPTOR_BUILD_TESTING=OFF`):
- `tests/handler_integration_test.cc` contains GoogleTest-based tests
- Tests are disabled because they require the same complex setup as production code
- **Before enabling GoogleTest**, we need to refactor:
  - Extract handler interfaces to enable mocking
  - Add dependency injection for dh_comms and kernelDB
  - Create test fixtures with minimal GPU initialization
  - Build message generation helpers for unit tests

**Note to future sessions**: Do not attempt to use GoogleTest until the above refactoring is complete. End-to-end tests via omniprobe are the current standard.

## Test Infrastructure

### Test Runner: `tests/run_handler_tests.sh`

Orchestrates end-to-end tests by sourcing feature-specific subscripts.

**Usage**:
```bash
./tests/run_handler_tests.sh
```

**Modular structure** (refactored 2026-03-04):
- `test_common.sh` — shared utilities, counters, colors, helper functions
- `run_basic_tests.sh` — Heatmap/MemoryAnalysis handler tests (tests 1-3)
- `run_block_filter_tests.sh` — `--filter-x/y/z` tests (tests 4-9)
- `run_library_filter_tests.sh` — `--library-filter` tests (tests 10-12)
- `run_handler_tests.sh` — main orchestrator that sources all subscripts

**What it does**:
1. Auto-detects build directory (`build/` relative to repo root)
2. Uses repo's omniprobe script (`${REPO_ROOT}/omniprobe/omniprobe`) - never hardcoded paths
3. Sets `ROCR_VISIBLE_DEVICES=0` to target GPU 0
4. Runs instrumented test kernels from `build/tests/test_kernels/`
5. Captures output and validates against expected patterns
6. Reports pass/fail with colored output

**Test helpers** (defined in subscripts):
```bash
# Basic pattern matching test (run_basic_tests.sh)
run_test "test_name" "/path/to/kernel" "AnalyzerName" "expected pattern"

# Block filter test (run_block_filter_tests.sh)
run_filter_test "test_name" "/path/to/kernel" expected_count "x_filter" "y_filter" "z_filter"

# Library filter test (run_library_filter_tests.sh)
run_library_filter_test "test_name" "/path/to/kernel" '{"exclude":[...]}' "present|absent" "pattern"
```

**Current tests** (12 total):
1-3. Basic handler tests (Heatmap, MemoryAnalysis)
4-9. Block filter tests (`--filter-x/y/z` CLI)
10-12. Library filter tests (`--library-filter` exclude/include)

### Triton Integration Tests: `tests/triton/`

End-to-end test for Triton-compiled kernels, verifying the full pipeline works with JIT-compiled code.

**Structure**:
- `run_test.sh` — test runner (requires `TRITON_REPO` env var; skips if unset)
- `vector_add.py` — minimal Triton vector-add kernel (4096 elements, 3 dispatches)

**Usage**:
```bash
TRITON_REPO=/path/to/triton ./tests/triton/run_test.sh
```

**Tests** (4 total):
1. Instrumentation plugin invoked during Triton JIT compilation
2. Instrumented kernel alternative found for `add_kernel`
3. L2 cache line use report generated
4. Bank conflicts report generated

**Prerequisites**:
- `TRITON_REPO` environment variable pointing to a Triton repo with `.venv/`
- omniprobe built with `TRITON_LLVM` (enables Triton plugin + co5 bitcode copy)

### rocBLAS Integration Tests: `tests/rocblas_filter/`

End-to-end test for rocBLAS kernel instrumentation (non-Tensile BLAS Level 1 kernels).

**Structure**:
- `run_test.sh` — test runner (requires `ROCBLAS_LIB_DIR` env var; skips if unset)

**Usage**:
```bash
ROCBLAS_LIB_DIR=/path/to/rocblas/lib ./tests/rocblas_filter/run_test.sh
```

**Tests** (5 total):
1. rocblas_sscal runs with MemoryAnalysis instrumentation (computation correct)
2. Instrumented alternative found for sscal kernel
3. L2 cache line use report generated
4. Bank conflicts report generated
5. Total elapsed time < 60 seconds

**Prerequisites**:
- `ROCBLAS_LIB_DIR` pointing to directory containing instrumented `librocblas.so`

### rocBLAS Offload Compression Tests: `tests/rocblas_offload_compression/`

Verifies CCOB (Compressed Clang Offload Bundle) decompression for rocBLAS builds
with offload compression enabled.

**Structure**:
- `run_test.sh` — test runner (requires `ROCBLAS_COMPRESSED_LIB_DIR`; skips if unset)

**Usage**:
```bash
ROCBLAS_COMPRESSED_LIB_DIR=/path/to/rocblas-with-compression/lib ./tests/rocblas_offload_compression/run_test.sh
```

**Tests** (5 total):
1. rocblas_sscal computation correct with compressed librocblas.so
2. Instrumented alternative found in decompressed `.hip_fatbin`
3. MemoryAnalysis reports (L2 cache + bank conflicts) generated
4. Total elapsed time < 120 seconds
5. rocblas_sgemm computation correct with compressed Tensile .co files

**Prerequisites**:
- `ROCBLAS_COMPRESSED_LIB_DIR` pointing to instrumented rocBLAS built WITH offload compression
- Pre-built test binaries in `tests/rocblas_filter/` (shared with Suite 3)

### Library Filter Chain Tests: `tests/library_filter_chain/`

Comprehensive tests for library include/exclude with dependency chains.

**Structure**:
- Standalone test with own `CMakeLists.txt`
- 6 shared libraries in 2 chains:
  - Static: `lib_static_head` → `lib_static_mid` → `lib_static_tail`
  - Dynamic: `lib_dynamic_head` → `lib_dynamic_mid` → `lib_dynamic_tail`
- Main app links static chain, dlopen's dynamic chain

**Usage**:
```bash
cd tests/library_filter_chain
./run_test.sh              # Full test (build + run)
./run_test.sh --no-instrument  # Test without instrumentation
./run_test.sh --build-only    # Build only
```

**Tests** (5 total):
1. App runs without omniprobe (basic functionality)
2. Baseline: static kernels instrumented, dynamic not
3. Exclude static libs: kernels not instrumented
4. Include dynamic_head (no deps): only head added + instrumented
5. Include with deps: all 3 dynamic libs added + instrumented

### Test Kernels: `tests/test_kernels/`

Simple HIP kernels for testing specific scenarios (auto-instrumented at build time)

### Test Kernels: `tests/test_kernels/`

Simple HIP kernels for testing specific scenarios. These are automatically instrumented at build time and used by the test runner.

**`simple_heatmap_test.cpp`**:
- Basic kernel with sequential memory access
- Tests: address message emission for memory heatmap handler
- Automatically instrumented and used by `heatmap_basic` test

**`simple_memory_analysis_test.cpp`**:
- Two kernels: coalesced and strided memory access
- Tests: uncoalesced access detection
- Automatically instrumented and used by `memory_analysis_cache_lines` test

**`hip_test_utils.h`**:
- `CHECK_HIP(call)` macro for clean HIP error checking
- Provides ASSERT_EQ-like functionality without GoogleTest
- Used by all test kernels

**Automatic Instrumentation** (via `tests/test_kernels/CMakeLists.txt`):
- Test kernels compiled with `-fpass-plugin=${INST_PLUGIN}`
- Plugin path: `build/external/instrument-amdgpu-kernels-rocm/build/lib/libAMDGCNSubmitAddressMessages-rocm.so`
- Bitcode files copied from dh_comms to plugin directories:
  - `copy_bitcode_to_rocm` — copies co6 files to ROCm plugin dir
  - `copy_bitcode_to_triton` — copies co5 files to Triton plugin dir (if `TRITON_LLVM` defined)
- Instrumentation happens at compile time, producing ready-to-run instrumented executables

**Building test kernels**:
```bash
cd build
cmake .. -DINTERCEPTOR_BUILD_TESTING=ON
ninja
```

Output: `build/tests/test_kernels/simple_heatmap_test`, `simple_memory_analysis_test`

## GoogleTest Integration (Currently Disabled)

### File: `tests/handler_integration_test.cc`

**Status**: Built but disabled in test runner

**Why disabled**: Requires same complex initialization as production:
- GPU context and HSA runtime
- Active dh_comms with allocated buffers
- kernelDB loaded
- No clean way to isolate handlers for unit testing

**What it contains**:
- 5 integration tests using GoogleTest framework:
  1. `MemoryHeatmapHandlesAddressMessages` — handler processes address messages
  2. `TimeIntervalHandlerProcessesMessages` — handler processes time intervals
  3. `MultipleHandlersProcessMessages` — multiple handlers work together
  4. `HandlerLifecycle` — start/stop/report cycle works correctly
  5. `HandlersWithNoMessages` — handlers handle empty input gracefully

**Test structure**:
```cpp
class HandlerIntegrationTest : public ::testing::Test {
protected:
    void SetUp() override {
        // Initialize HIP device
    }
    void TearDown() override {
        hipDeviceReset();
    }
};
```

**Building** (when ready):
```bash
cmake .. -DINTERCEPTOR_BUILD_TESTING=ON
ninja handler_integration_test
./tests/handler_integration_test
```

### CMake Configuration

**`tests/CMakeLists.txt`**:
- Finds GoogleTest (`find_package(GTest REQUIRED)`)
- Links against handler libraries
- Includes dh_comms and kerneldb headers
- Creates `handler_integration_test` executable

**Main `CMakeLists.txt`**:
- Conditionally includes `tests/` and `tests/test_kernels/`
- Controlled by `INTERCEPTOR_BUILD_TESTING` option
- Currently defaults to OFF

## Test Execution

### Running Tests

**Primary method** (all suites via top-level runner):
```bash
# From repository root (runs all 4 suites):
ROCBLAS_LIB_DIR=/path/to/rocblas/lib TRITON_REPO=/path/to/triton ./tests/run_all_tests.sh

# Without optional env vars (rocBLAS + Triton suites skip):
./tests/run_all_tests.sh

# Individual suites:
./tests/run_handler_tests.sh
./tests/library_filter_chain/run_test.sh
ROCBLAS_LIB_DIR=/path/to/rocblas/lib ./tests/rocblas_filter/run_test.sh
TRITON_REPO=/path/to/triton ./tests/triton/run_test.sh
```

**Expected output**:
```
[TEST 1] heatmap_basic
  ✓ PASS - Found expected pattern: 'memory heatmap report'
[TEST 2] memory_analysis_cache_lines
  ✓ PASS - Found expected pattern: 'L2 cache line use report'
[TEST 3] heatmap_page_accesses
  ✓ PASS - Found expected pattern: 'accesses'

All tests passed!
```

**Test artifacts**:
- Output saved to `tests/test_output/*.out`
- Directory ignored in `.gitignore` (not tracked)

### GoogleTest Execution (when enabled)

```bash
cd build
cmake .. -DINTERCEPTOR_BUILD_TESTING=ON
ninja handler_integration_test
./tests/handler_integration_test
```

## Key Invariants

- Test output directory (`tests/test_output/`) is not tracked in git
- Test kernels use `CHECK_HIP` macro for clean error handling (not GoogleTest macros)
- End-to-end tests validate full pipeline, not individual components
- Tests must run on real GPU hardware (device 0 via `ROCR_VISIBLE_DEVICES=0`)

## Dependencies

### For End-to-End Tests
- Working omniprobe installation
- Instrumented test kernels
- ROCm/HIP runtime
- Available GPU device

### For GoogleTest (when enabled)
- GoogleTest library (`libgtest.so`)
- All handler libraries built
- dh_comms and kernelDB submodules
- HIP runtime for GPU kernels

## Rejected Approaches

- **Unit testing handlers without refactoring**: Handlers require too much infrastructure (GPU, dh_comms, kernelDB) to test in isolation. Would require extensive mocking or a major refactor to add dependency injection. End-to-end tests provide better coverage with less effort.

- **Mocking GPU message buffers**: Attempted to create mock message streams for handlers, but handler behavior depends on real GPU timing, memory layout, and concurrent message processing. Mocks would be too complex and wouldn't catch real integration issues.

## Open Questions

- What refactoring is needed to enable true unit tests with GoogleTest?
- Should we create a test fixture library for handler testing?

## Recent Changes

**2026-03-05**:
- Added rocBLAS integration test suite (`tests/rocblas_filter/`) — uses `ROCBLAS_LIB_DIR` env var
- Added Triton integration test suite (`tests/triton/`)
- Split `copy_bitcode_files` into `copy_bitcode_to_rocm` (co6) and `copy_bitcode_to_triton` (co5)
- Triton test uses `TRITON_REPO` env var; skips gracefully if unset
- Test output colors changed from yellow to orange (256-color ANSI) for readability on light backgrounds
- Suite 2 (library filter chain) output cleaned up: build/run output suppressed, only test summaries shown
- `run_all_tests.sh` now runs 4 suites: handler, library filter chain, rocBLAS, Triton

**2026-03-05** (CCOB support):
- Added rocBLAS offload compression test suite (`tests/rocblas_offload_compression/`)
- Uses `ROCBLAS_COMPRESSED_LIB_DIR` env var; skips gracefully if unset
- `run_all_tests.sh` now runs 5 suites: handler, library filter chain, rocBLAS, offload compression, Triton

**2026-03-04**:
- Refactored test scripts into modular structure (test_common.sh + feature subscripts)
- Added `tests/library_filter_chain/` comprehensive test for library include/exclude
- Tests now cover: basic handlers, block filters, library filters, dependency resolution

**2026-03-03** (commit 7d7da52):
- Enabled automatic instrumentation of test kernels at build time
- Test kernels now compiled with `-fpass-plugin` to automatically instrument
- Added bitcode copy targets to copy dh_comms bitcode to plugin directories
- Test runner updated to use project's own test kernels instead of external kernel

## Last Verified
Date: 2026-03-05
- Handler tests: 12/12 passing (3 handler + 6 block filter + 3 library filter)
- Library filter chain: 5/5 passing
- rocBLAS integration: 5/5 passing (requires `ROCBLAS_LIB_DIR`; skips otherwise)
- rocBLAS offload compression: 5/5 passing (requires `ROCBLAS_COMPRESSED_LIB_DIR`; skips otherwise)
- Triton integration: 4/4 passing (requires `TRITON_REPO`; skips otherwise)

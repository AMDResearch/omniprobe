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

Bash script that orchestrates end-to-end tests:

**Location**: `tests/run_handler_tests.sh`

**Usage**:
```bash
./tests/run_handler_tests.sh
```

**What it does**:
1. Auto-detects build directory (`build/` relative to repo root)
2. Finds omniprobe binary (`~/work/.local/bin/logDuration/omniprobe`)
3. Sets `ROCR_VISIBLE_DEVICES=0` to target GPU 0
4. Runs instrumented test kernels from `build/tests/test_kernels/`
5. Captures output and validates against expected patterns
6. Reports pass/fail with colored output
7. Provides helpful error messages if tests aren't built

**Test format**:
```bash
run_test "test_name" \
    "/path/to/instrumented/kernel" \
    "AnalyzerName" \
    "expected pattern in output"
```

**Current tests**:
1. `heatmap_basic` — Memory heatmap produces report
2. `memory_analysis_cache_lines` — Memory analysis reports cache line usage
3. `heatmap_page_accesses` — Heatmap counts page accesses

**Test kernels**: Uses project's own automatically instrumented test kernels:
- `build/tests/test_kernels/simple_heatmap_test`
- `build/tests/test_kernels/simple_memory_analysis_test`
- Instrumented at build time via LLVM pass plugin

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
- Bitcode files automatically copied from dh_comms to plugin directory via `copy_bitcode_files` target
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

**Primary method** (end-to-end via omniprobe):
```bash
cd /work1/amd/rvanoo/repos/omniprobe
./tests/run_handler_tests.sh
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

- Should simple test kernels be instrumented and integrated into `run_handler_tests.sh`?
- What refactoring is needed to enable true unit tests with GoogleTest?
- Should we create a test fixture library for handler testing?

## Recent Changes

**2026-03-03** (commit 7d7da52):
- Enabled automatic instrumentation of test kernels at build time
- Test kernels now compiled with `-fpass-plugin` to automatically instrument
- Added `copy_bitcode_files` target to copy dh_comms bitcode to plugin directory
- Test runner updated to use project's own test kernels instead of external kernel
- Test runner auto-detects build directory and provides better error messages
- Test kernels now in `build/tests/test_kernels/` (automatically instrumented)

## Last Verified
Commit: 7d7da52
Date: 2026-03-03
All 3 end-to-end tests passing with automatically instrumented kernels ✓

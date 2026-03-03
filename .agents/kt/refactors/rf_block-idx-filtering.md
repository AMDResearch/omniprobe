# Refactor: Block Index Filtering in dh_comms

## Status
- [ ] TODO
- [ ] In Progress
- [ ] Blocked
- [x] Done

### Blocker (if blocked)
N/A

## Objective
Add message filtering capability to dh_comms based on workgroup coordinates (block_idx_x/y/z). Messages are filtered in the host processing loop before being passed to handlers, controlled by environment variables.

## Refactor Contract

### Goal
Implement message filtering in `dh_comms::processing_loop()` that checks block_idx_x/y/z fields from wave headers against filter ranges specified via environment variables:
- `DH_COMMS_GROUP_FILTER_X` - filter on block_idx_x
- `DH_COMMS_GROUP_FILTER_Y` - filter on block_idx_y
- `DH_COMMS_GROUP_FILTER_Z` - filter on block_idx_z

Each variable accepts:
- Single integer `i` → pass messages where block_idx == i
- Range `i:j` → pass messages where i <= block_idx < j (half-open range)
- Unset → no filtering on that dimension

Multiple filters are AND-ed (message must match all specified filters).

### Non-Goals / Invariants
- **ABI compatibility**: NO - adding filter state to `dh_comms` class changes ABI; rebuild required
- **API compatibility**: YES - external API unchanged (filtering is transparent to callers)
- **Performance constraints**: Must optimize for no-filter case (zero overhead when env vars not set)
- **Threading model**: Single-threaded processing loop unchanged; filters read once in constructor
- **Other invariants**:
  - Invalid filter values generate warning and disable filtering (graceful degradation)
  - Empty ranges (i==j) result in no messages passing that filter
  - Filters with j<i are invalid (warning + disable)

### Verification Gates
How to prove correctness:
- **Build**: `cmake --build build/` succeeds
- **Existing tests**: `cd build && ctest` passes (regression check)
- **New tests**: New filtering test kernels pass under omniprobe with various filter combinations
- **Runtime**: No performance regression when filters disabled (verified via existing tests)

## Scope

### Affected Symbols
- `dh_comms::dh_comms()` — parse env vars in constructor, store filter state
- `dh_comms::processing_loop()` — add filter check before invoking handler chain
- New helper: `dh_comms::parse_filter_env()` — parse "i" or "i:j" format
- New helper: `dh_comms::message_passes_filter()` — apply filter to wave header

### Expected Files
- `external/dh_comms/include/dh_comms.h` — confirmed (add filter state members)
- `external/dh_comms/src/dh_comms.cpp` — confirmed (constructor + processing_loop + helpers)
- `tests/test_kernels/block_filter_test.cpp` — new test kernel
- `tests/test_kernels/CMakeLists.txt` — confirmed (add new test target)
- `tests/run_handler_tests.sh` — confirmed (add filter test cases)

### Call Graph Impact
- `dh_comms::processing_loop()` calls new `message_passes_filter()` before `message_handler_chain_.handle()`
- No impact on device code (filtering is host-side only)
- No impact on message handlers (they see filtered stream)

### Risks
- **Performance regression**: Mitigated by fast-path check when filters disabled
- **Parser robustness**: Mitigated by defensive parsing with clear error messages
- **Test coverage**: Start with simple cases, expand as needed
- **Submodule coordination**: Changes in dh_comms submodule require rebuild of omniprobe

## Plan of Record

### Micro-steps
1. [x] Write test kernel with known block dimensions - Gate: compile + runs
   - Create `block_filter_test.cpp` launching kernels with specific grid sizes
   - Kernel reads/writes arrays based on block_idx coordinates
   - Use AddressLogger analyzer (requires address instrumentation plugin)
   - Kernel should generate predictable memory accesses per workgroup

2. [x] Run baseline test without filtering - Gate: understand output format
   - VERIFIED: block_idx_x/y/z fields present in JSON messages
   - 64 unique block coordinates (8x4x2 grid fully captured)
   - 3 messages per block (constant load + global read + global write)
   - 192 total messages captured
   - Run via omniprobe with AddressLogger analyzer
   - Examine output to verify block_idx fields are present in messages
   - Document expected message count and block_idx values
   - Establish baseline for comparison

3. [x] Add test cases with environment variables set - Gate: tests fail (expected)
   - Test 4: No filter (baseline - all messages pass) - PASSES
   - Test 5: Single value filter (DH_COMMS_GROUP_FILTER_X=5) - FAILS (expected)
   - Test 6: Range filter (DH_COMMS_GROUP_FILTER_X=2:6) - FAILS (expected)
   - Test 7: Multi-dimension filter (X=2, Y=1) - FAILS (expected)
   - Test 8: Empty range (X=3:3, expect 0 messages) - FAILS (expected)
   - Test 9: Z dimension filter (Z=1) - FAILS (expected)
   - Tests validate both count AND block_idx values are within filter range

4. [x] Design filter state structure - Gate: compile
   - Added `block_idx_filter_t` struct with enabled, min, max fields
   - Added filter_x_, filter_y_, filter_z_ members to dh_comms class
   - Added any_filter_enabled_ for fast-path optimization
   - Added parse_filter_env() and message_passes_filter() method declarations

5. [x] Implement environment variable parser - Gate: compile
   - Added `parse_filter_env()` static method
   - Handles single int "42" -> [42, 43), range "10:20" -> [10, 20)
   - Invalid formats generate warning and disable filter

6. [x] Call parser in dh_comms constructor - Gate: compile
   - Parse DH_COMMS_GROUP_FILTER_{X,Y,Z} via std::getenv in initializer list
   - Stores results in filter_x_, filter_y_, filter_z_ members
   - Prints filter configuration if verbose mode enabled

7. [x] Implement message filter logic - Gate: compile
   - Added `message_passes_filter()` method
   - Fast-path: early return true if !any_filter_enabled_
   - Checks each dimension against half-open range [min, max)

8. [x] Integrate filter into processing_loop - Gate: all tests pass
   - Added filter check before `message_handler_chain_.handle()` call
   - All 9 tests pass (3 existing + 6 new filter tests)
   - No regression: existing heatmap/memory analysis tests pass unchanged

### Current Step
COMPLETE - All micro-steps done

## Progress Log
<!-- Append updates, don't delete -->

### Session 2026-03-03 (Initial)
- Refactor initialized
- Contract established with user
- Revised plan to test-first approach (write tests before implementation)
- Next: Begin step 1 (write test kernel)

### Session 2026-03-03 (Suspended)
- Completed: Step 1 (test kernel written and compiled)
- Gates: Compile gate passed - block_filter_test builds successfully
- Discovered:
  - Test kernel launches 8x4x2 grid (64 blocks total) with blocksize=64
  - Instrumentation plugin successfully injects address trace functions
  - Plugin detects CONSTANT LOAD, GLOBAL LOAD, and GLOBAL STORE operations
  - Test kernel accesses memory based on linearized block coordinates
- Files created:
  - `tests/test_kernels/block_filter_test.cpp` - test kernel with 3D grid
  - Updated `tests/test_kernels/CMakeLists.txt` to build new test
- Next: Step 2 - Run baseline test with omniprobe + AddressLogger to examine output format and verify block_idx fields are present in messages

### Session 2026-03-03 (Final)
- Completed: Steps 2-8 (all remaining steps)
- Gates: All tests pass (9/9)
- Implementation summary:
  - Added `block_idx_filter_t` struct to dh_comms.h
  - Added `parse_filter_env()` to parse "N" or "N:M" env var format
  - Added `message_passes_filter()` to check wave_header against filters
  - Integrated filter into `processing_loop()` before handler invocation
  - Updated test script to use repo's omniprobe (not installed copy)
  - Tests validate both message count AND block_idx values within filter range
- Files modified:
  - `external/dh_comms/include/dh_comms.h` - filter struct + member declarations
  - `external/dh_comms/src/dh_comms.cpp` - filter implementation
  - `tests/run_handler_tests.sh` - 6 new filter test cases + helper function

## Rejected Approaches
None yet.

## Open Questions
None currently.

## Last Verified
Commit: (pending commit)
Date: 2026-03-03
All 9 tests pass, implementation complete.

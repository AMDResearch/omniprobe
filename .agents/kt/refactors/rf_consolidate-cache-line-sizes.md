# Refactor: Consolidate Cache Line Size Definitions

## Status
- [x] Done

## Objective
Create a single source of truth for L2 cache line sizes by consolidating duplicate definitions across the codebase into a shared header file.

## Refactor Contract

### Goal
Eliminate duplicate cache line size definitions in host-side code by creating a canonical header (`gpu_arch_constants.h`) in the dh_comms submodule that can be included by all code that needs architecture-specific cache line sizes.

### Non-Goals / Invariants
- **ABI compatibility**: No changes to message formats or public APIs
- **Behavior**: Memory analysis results must remain identical before and after refactoring
- **Out of scope**: Device-side files in `external/instrument-amdgpu-kernels/instrumentation/` (unused code, will be cleaned up separately)
- **Submodule boundaries**: Keep the new header in dh_comms where the `gcnarch` enum is defined

### Verification Gates
- Build: `ninja` in build/ completes without errors
- Tests: All 3 end-to-end tests pass (`./tests/run_handler_tests.sh`)
- Integration: Memory analysis reports show correct cache line sizes for test hardware
- Comparison: Before/after refactoring produces identical results

## Scope

### Current Duplicate Definitions

| Location | Lines | Type | Status |
|----------|-------|------|--------|
| `src/memory_analysis_handler.cc` | 40-48 | Array indexed by `gcnarch` enum | ✅ Correct usage |
| `src/memory_analysis_handler.cc` | 946-952 | String-based map in `report_json()` | ❌ Duplicate |

**Architecture values**:
- gfx906: 64 bytes
- gfx908: 64 bytes
- gfx90a: 128 bytes
- gfx940: 128 bytes
- gfx941: 128 bytes
- gfx942: 128 bytes

### Files to Create/Modify

**New file**:
- `external/dh_comms/include/gpu_arch_constants.h` — Canonical cache line size definitions

**Modified files**:
- `src/memory_analysis_handler.cc` — Remove local array, use new header, simplify `report_json()`
- `.agents/kt/memory_analysis.md` — Update documentation about cache line sizes

### Key Design Decisions

1. **Location**: Place header in `external/dh_comms/include/` because:
   - dh_comms already defines the `gcnarch` enum
   - Keeps architecture-related constants co-located
   - Already accessible from main project (dh_comms is a dependency)
   - Provides foundation for future device-side integration

2. **API**: Provide both array access and helper function:
   - `L2_CACHE_LINE_SIZES[]` array for direct access
   - `get_l2_cache_line_size(uint8_t arch)` helper for bounds checking
   - Optional device-side `DEVICE_L2_CACHE_LINE_SIZE` for future use

3. **Namespace**: Use `dh_comms::gpu_arch_constants` to avoid conflicts

## Plan of Record

### Phase 1: Create Canonical Header
1. [x] Create `external/dh_comms/include/gpu_arch_constants.h`
2. [x] Define `L2_CACHE_LINE_SIZES[]` array with values indexed by `gcnarch` enum
3. [x] Add `get_l2_cache_line_size(uint8_t arch)` helper function
4. [x] Add device-side `DEVICE_L2_CACHE_LINE_SIZE` constexpr (for future)
5. [x] Verify header compiles in isolation

### Phase 2: Update memory_analysis_handler.cc
6. [x] Add `#include "gpu_arch_constants.h"`
7. [x] Delete local `L2_cache_line_sizes[]` array definition (lines 40-48)
8. [x] Update line 357 to use `dh_comms::gpu_arch_constants::get_l2_cache_line_size()`
9. [x] Simplify `report_json()` (lines 946-958) to use enum-based lookup
10. [x] Build and verify no compilation errors

### Phase 3: Test and Verify
11. [x] Run `./tests/run_handler_tests.sh` — all 3 tests must pass
12. [x] Run memory analysis on test kernel, compare output before/after
13. [x] Verify JSON report has correct `cache_line_size` in metadata
14. [x] Check verbose output shows correct cache line size (0x40 for gfx906, 0x80 for gfx90a)

### Phase 4: Update Documentation
15. [x] Update `.agents/kt/memory_analysis.md` Key Invariants section
16. [x] Note that cache line sizes are now defined in `gpu_arch_constants.h`
17. [x] Document that this provides foundation for future device-side use

### Current Step
**REFACTOR COMPLETE** - All phases finished successfully

## Progress Log

### Session 2026-03-03 - Implementation Complete
- **Phase 1**: Created `external/dh_comms/include/gpu_arch_constants.h`
  - Defined `L2_CACHE_LINE_SIZES[]` array indexed by gcnarch enum
  - Added `get_l2_cache_line_size(uint8_t arch)` helper with bounds checking
  - Added `arch_string_to_enum()` helper for JSON reporting
  - Added device-side `DEVICE_L2_CACHE_LINE_SIZE` constexpr (future use)
  - Build verified header compiles ✓
- **Phase 2**: Updated `src/memory_analysis_handler.cc`
  - Added include for `gpu_arch_constants.h`
  - Deleted local `L2_cache_line_sizes[]` array (lines 40-48)
  - Updated `handle_cache_line_count_analysis()` to use `gpu_arch_constants::get_l2_cache_line_size()`
  - Simplified `report_json()` to use `arch_string_to_enum()` + lookup instead of string map
  - Build succeeded ✓
- **Phase 3**: Tests passed
  - All 3 tests in `./tests/run_handler_tests.sh` pass ✓
  - Memory analysis correctly reports cache line usage on gfx90a (128-byte cache lines)
- **Phase 4**: Updated documentation
  - Updated `.agents/kt/memory_analysis.md` Key Invariants section
  - Added note about `gpu_arch_constants.h` in Dependencies
  - Added entry to Recent Changes

**Net changes**:
- New file: `external/dh_comms/include/gpu_arch_constants.h` (+82 lines)
- Modified: `src/memory_analysis_handler.cc` (-9 lines, simplified)
- Modified: `.agents/kt/memory_analysis.md` (documentation)

**Commits**:
- `282a26b` (dh_comms): Add GPU architecture constants header with L2 cache line sizes
- `41ab393` (main): Consolidate L2 cache line size definitions into shared header

**Final verification**: All 3 end-to-end tests pass ✓

### Session 2026-03-03 - Planning
- Analyzed codebase and found duplicate cache line size definitions
- Discovered device-side files in instrument-amdgpu-kernels also hard-code values
- User confirmed device-side files are unused and will be cleaned up separately
- Created refactor dossier focused on host-side consolidation only
- Decision: Create header in dh_comms submodule for co-location with `gcnarch` enum

## Architecture Context

The `gcnarch` enum is defined in `external/dh_comms/include/message.h`:
```cpp
namespace gcnarch {
enum : uint8_t {
    unsupported = 0,
    gfx906 = 1,
    gfx908 = 2,
    gfx90a = 3,
    gfx940 = 4,
    gfx941 = 5,
    gfx942 = 6
};
}
```

Device code sets `message.wave_header().arch` to this enum value at compile time based on GPU target.

## Known Limitations

- Device-side code in `external/instrument-amdgpu-kernels/instrumentation/` still has hard-coded values (out of scope for this refactor)
- JSON report generation requires mapping from string architecture names to enum values (could be improved in future)

## Last Verified
Commit: 41ab393 (main repo), 282a26b (dh_comms submodule)
Date: 2026-03-03
Status: Complete - refactor finalized and committed

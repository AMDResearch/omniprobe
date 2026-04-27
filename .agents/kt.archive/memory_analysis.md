# Memory Analysis Handler

## Responsibility
Analyzes memory access messages from instrumented kernels. For global memory: detects uncoalesced accesses by comparing actual cache lines used vs minimum needed. For LDS: detects bank conflicts.

## Core Concepts
- **Cache Line Analysis**: Compare actual cache lines accessed vs optimal (consecutive) access pattern
- **Bank Conflict Detection**: LDS is partitioned into 32 banks; simultaneous accesses to same bank by different lanes cause serialization
- **Conflict Sets**: Groups of lanes that execute in the same phase (depends on access size)
- **Source Location Tracking**: Issues tracked by file/line/column from DWARF info

## Key Invariants
- Cache line sizes are architecture-specific (gfx906/908: 64 bytes, gfx90a/940/941/942: 128 bytes)
  - Defined in `external/dh_comms/include/gpu_arch_constants.h`
  - Indexed by `gcnarch` enum from message wave header
- Bank conflict analysis depends on access size (1/2/4 bytes → {0..31}, {32..63}; 8 bytes → 4 sets; 16 bytes → 8 non-contiguous sets)
- ISA-level access size may differ from IR-level (dwordx4 optimization)

## Data Flow
1. Receive `message_t` with address array (64 lanes) + DWARF info
2. Determine memory type (global vs LDS) from address space
3. For global: count cache lines, compare to minimum
4. For LDS: compute bank conflicts using conflict sets
5. Accumulate stats by source location
6. On `report()`: output summary grouped by file/line

## Interfaces
- `memory_analysis_handler_t(kernel, dispatch_id, location, verbose)` — `inc/memory_analysis_handler.h:82`
- `handle(message)` — process single message — `inc/memory_analysis_handler.h:87`
- `handle(message, kernel_name, kdb)` — with ISA correlation — `inc/memory_analysis_handler.h:88`
- `report()` — output analysis results — `inc/memory_analysis_handler.h:89`
- `report(kernel_name, kdb)` — with ISA details — `inc/memory_analysis_handler.h:90`

## Dependencies
- dh_comms (message types, handler base class, GPU architecture constants)
  - `gpu_arch_constants.h` — L2 cache line sizes indexed by gcnarch enum
- kerneldb (ISA instruction matching for access size correction)

## Also Load
- `dh_comms` sub-project KT for message format
- `kerneldb` sub-project KT for ISA correlation

## Key Classes

### conflict_set
Represents a set of lanes that may cause bank conflicts with each other.

### memory_analysis_handler_t
Main handler class. Inherits from `message_handler_base`.

**Key members**:
- `conflict_sets` — map of access size → vector of conflict_set
- `global_accesses` — file/line/column → global memory stats
- `lds_accesses` — file/line/column → LDS stats
- `instr_size_map` — ISA instruction → access size mapping

## Output Formats
- Console (human-readable)
- CSV (`LOGDUR_LOG_FORMAT=csv`)
- JSON (`LOGDUR_LOG_FORMAT=json`)

## Known Limitations
- IR-level access size may not match ISA-level (handled via kerneldb correlation)
- Conflict set calculation for 16-byte accesses has complex non-contiguous lane groups

## Recent Changes
- **2026-03-03**: Consolidated cache line size definitions into `gpu_arch_constants.h` in dh_comms submodule
- **2026-03-03**: Removed `memory_analysis_wrapper_t` — handler now used directly in plugins and comms_mgr

## Last Verified
Commit: 6ce0281
Date: 2026-03-03

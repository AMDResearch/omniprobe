# Interceptor (liblogDuration64)

## Responsibility
HSA tools library that intercepts kernel dispatches at runtime. When a dispatch occurs, it checks for an instrumented kernel variant and optionally swaps in the instrumented version with modified kernel arguments.

## Core Concepts
- **HSA Tools Library**: Loaded via `HSA_TOOLS_LIB` env var when HSA runtime initializes
- **API Table Hooking**: Modifies HSA function pointer table to intercept calls
- **Kernel Object Map**: Maps kernel handles to descriptors (name, symbol, agent, kernarg_size)
- **Signal Pool**: Reusable HSA signals for tracking kernel completion
- **Dispatch Controller**: Decides which dispatches to instrument based on config

## Key Invariants
- Singleton pattern (`hsaInterceptor::getInstance()`)
- Original HSA API preserved and callable via saved table
- Signal runner thread waits on kernel completion signals
- Shutdown sequence: set `shutting_down_` flag, join threads, cleanup

## Data Flow
1. `OnLoad()` called by HSA runtime → creates singleton, hooks API
2. `hsa_queue_create()` intercepted → registers queue + agent
3. `hsa_executable_symbol_get_info()` intercepted → captures kernel objects
4. `OnSubmitPackets()` intercepted → `doPackets()` decides instrumented vs original
5. If instrumented: `fixupPacket()` + `fixupKernArgs()` add dh_comms descriptor
6. Signal runner thread processes completed kernels, invokes handler reports

## Interfaces
- `OnLoad(HsaApiTable*, ...)` — HSA entry point — `src/interceptor.cc:990`
- `OnUnload()` — HSA cleanup — `src/interceptor.cc:1028`
- `hsaInterceptor::getInstance()` — singleton accessor — `inc/interceptor.h:120`
- `hsaInterceptor::doPackets()` — packet interception logic — `inc/interceptor.h:113`
- `hsaInterceptor::fixupPacket()` — modify dispatch packet — `inc/interceptor.h:112`
- `hsaInterceptor::fixupKernArgs()` — add dh_comms ptr to args — `inc/interceptor.h:111`

## Dependencies
- dh_comms (device-host communication)
- kerneldb (ISA extraction for handler correlation)
- comms_mgr (dh_comms object pooling)
- Message handlers (via plugin system)

## Also Load
- `comms_mgr.md` for buffer pool management
- `dh_comms` sub-project KT for message passing details

## Key Classes

### hsaInterceptor
Central singleton managing all interception state.

**Key members**:
- `apiTable_` — original HSA API table
- `kernel_objects_` — map of kernel handle → descriptor
- `pending_signals_` — signals awaiting completion
- `comms_mgr_` — manages dh_comms object pool
- `kdbs_` — per-agent kernelDB instances
- `dispatcher_` — dispatch selection logic
- `library_filter_` — filters which libraries are scanned (via `LOGDUR_LIBRARY_FILTER`)

**Key methods**:
- `hookApi()` — install function intercepts
- `addKernel()` — register discovered kernel
- `doPackets()` — intercept and possibly modify dispatch
- `shutdown()` — clean shutdown sequence

### LibraryFilter
Filters which libraries are scanned for kernels, configured via `--library-filter` CLI / `LOGDUR_LIBRARY_FILTER` env var.

**Location**: `inc/library_filter.h`, `src/library_filter.cc`

**Key methods**:
- `loadConfig(path)` — parse JSON config with include/include_with_deps/exclude arrays
- `isExcluded(path)` — check if library should be skipped (glob patterns → regex)
- `getIncludedFiles()` — expand include patterns to file list
- `getIncludedFilesWithDeps()` — expand include_with_deps + resolve ELF dependencies

**Dependencies**: libelf (for `getElfDependencies()` which parses DT_NEEDED entries)

## Known Limitations
- Assumes single interceptor (singleton)
- Thread model: one signal runner, one comms runner

## Rejected Approaches
- **Per-dispatch dh_comms allocation**: Too slow; pooling required for performance
- **kernelDB auto-discovery with filter**: The `kernelDB(agent, "")` constructor auto-discovers all shared libraries, bypassing any filter. Must use `kernelDB(agent)` single-arg constructor and manually call `addFile()` for each filtered file.

## Open Questions
- None currently documented

## Last Verified
Date: 2026-03-04

# Interceptor

## Responsibility

HSA tools library that intercepts kernel dispatches at runtime. When a dispatch
occurs, it checks for an instrumented kernel variant and optionally swaps in the
instrumented version with modified kernel arguments.

## Key Source Files

| File | Purpose |
|------|---------|
| `src/interceptor.cc` | Main interceptor implementation |
| `inc/interceptor.h` | `hsaInterceptor` class definition |
| `inc/library_filter.h` | Library include/exclude filtering (header) |
| `src/library_filter.cc` | Library include/exclude filtering (impl) |

## Key Types and Classes

| Type | Location | Purpose |
|------|----------|---------|
| `hsaInterceptor` | `inc/interceptor.h` | Central singleton managing all interception state |
| `LibraryFilter` | `inc/library_filter.h` | Filters which libraries are scanned for kernels |

## Key Functions and Entry Points

| Function | Location | Purpose |
|----------|----------|---------|
| `rocprofiler_configure()` | `src/interceptor.cc` | rocprofiler-sdk tool entry point (`extern "C"`) |
| `rocp_hsa_table_callback()` | `src/interceptor.cc` | Receives `HsaApiTable*`, calls `getInstance()` |
| `OnLoad()` | `src/interceptor.cc` | Legacy error guard, aborts with message to unset `HSA_TOOLS_LIB` |
| `hsaInterceptor::getInstance()` | `inc/interceptor.h:120` | Singleton accessor |
| `hsaInterceptor::doPackets()` | `inc/interceptor.h:113` | Packet interception logic |
| `hsaInterceptor::fixupPacket()` | `inc/interceptor.h:112` | Modify dispatch packet |
| `hsaInterceptor::fixupKernArgs()` | `inc/interceptor.h:111` | Add `dh_comms` ptr to args |

## Data Flow

1. `rocprofiler_configure()` called by rocprofiler-sdk -- registers HSA table callback -- callback receives `HsaApiTable*` -- creates singleton, hooks API.
2. `hsa_queue_create()` intercepted -- registers queue + agent.
3. `hsa_executable_symbol_get_info()` intercepted -- captures kernel objects into `kernel_objects_` AND registers them in `kernel_cache_` (coCache) via `registerRuntimeKernel()`.
4. Startup: code objects registered in `kernel_cache_` (coCache) but kernelDB scanning is deferred.
5. `OnSubmitPackets()` intercepted -- `doPackets()` decides instrumented vs original.
6. `fixupPacket()`: on-demand scanning -- if kernel not in kernelDB, `scanCodeObject()` called.
7. If instrumented: `fixupPacket()` + `fixupKernArgs()` add `dh_comms` descriptor; logs source library paths.
8. Signal runner thread processes completed kernels, invokes handler reports.

## Invariants

- Singleton pattern (`hsaInterceptor::getInstance()`).
- Original HSA API preserved and callable via saved table.
- Signal runner thread waits on kernel completion signals.
- Shutdown sequence: set `shutting_down_` flag, join threads, cleanup.

## Dependencies

- `handler-pipeline.md` — handler plugin loading and dh_comms pool management
- Sub-project: dh_comms — device-host communication
- Sub-project: kerneldb — ISA extraction and code object scanning

## Negative Knowledge

- **Per-dispatch dh_comms allocation:** Too slow; pooling required for performance. Always use `comms_mgr` checkout/checkin.
- **kernelDB auto-discovery with filter:** The `kernelDB(agent, "")` constructor auto-discovers all shared libraries, bypassing any filter. Must use `kernelDB(agent)` single-arg constructor and manually call `addFile()`.
- **Scan-everything-at-startup:** Scanning all code objects at startup caused >10 min delays with large libraries like rocBLAS (~12,000 kernels). Replaced with on-demand per-code-object scanning at dispatch time.
- **Library filter requires raw ELF:** `isValidElf()` checks for `0x7f` ELF magic bytes. Clang Offload Bundles are rejected. Must unbundle first.

## Open Questions

None.

## Last Verified

2026-03-24

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
   **Two different registrations, and the difference matters.** For the process's own binary and
   its shared libraries -- code the application loads itself -- `addFile()` is called with
   `app_loads_object=true` and only *indexes* the extracted files: it fills `arg_map_` and
   `kernel_co_map_` and creates **no HSA executable**. Symbols come from
   `registerRuntimeKernel()` in step 3, off the executable the application loaded. For a Triton
   JIT cache or a `--library-filter` include -- files the application never loads -- `addFile()`
   still builds a private executable, because the instrumented kernels exist nowhere else.
   Building one for code the application already had is what caused
   `bf_hip-duplicate-code-object-load`: the private copy's `__constant__` segment is never
   initialised, so clones dispatched from it read `__device__`/`__constant__` globals as zero.
5. `OnSubmitPackets()` intercepted -- `doPackets()` decides instrumented vs original. The `-k`
   kernel filter is applied **here**, by `runKernelInstrumented()`, against a regex compiled once
   at init. It gates the clone swap only; it does not gate what gets indexed, so filtering never
   costs source-line attribution for the kernels that are instrumented.
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

## Negative Knowledge — the lookup key is a demangler's output, and that is fragile

`lookup_map_` (`src/utils.cc:690`) is keyed by `kernelDB::demangleName(<symbol>)` for originals and
clones alike, and at dispatch `interceptor.cc:790` reconstructs the clone's key from the original's
with `getInstrumentedName` (`src/utils.cc:117`). **The key's form therefore depends on whether the
demangler happened to succeed**, and `getInstrumentedName` has two entirely different branches for
the two cases.

Measured 2026-09-08: libstdc++'s clone-suffix grammar accepts `.<identifier>` (letter- or
underscore-leading) and `.<all-digits>`, but rejects a digit-leading token containing letters. So
for an internal-linkage kernel a hash beginning `a`–`f` demangles and one beginning `0`–`9` does
not — and the two defects (this one and the clone-naming one in `instrumentation`) **cancel
exactly when both demangles fail together**. That is ~62.5% of translation units, which is why
this went unnoticed.

The deeper design point, recorded because it outlives the bug: a map keyed by a string whose form
depends on a demangler's success is a latent hazard independent of `.intern.`. Re-keying on the
raw symbol is a refactor, not a bug fix, and is a declared non-goal of `bf_intern-clone-name`.

## Open Questions

None.

## Last Verified

2026-03-24
2026-09-08 (data flow steps 4-5 rewritten for bf_hip-duplicate-code-object-load: app-loaded code objects are indexed rather than loaded into a private executable, and the -k filter now gates the clone swap at dispatch)
2026-09-08 (lookup-key scheme and its dependence on demangler success; measured)

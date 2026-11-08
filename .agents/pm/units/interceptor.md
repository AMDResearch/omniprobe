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

### Failure handling on the dispatch path (2026-11-08)

- **`-k` semantics:** `runKernelInstrumented()` is `std::regex_search(name, kernel_filter_regex_)`
  on the **demangled** name (`src/interceptor.cc`; same at index time in `src/utils.cc`
  `coCache::addFile`). Substring search, so `gpuMain` matches `gpuMain2<4>`; template kernels'
  demangled names begin with the return type (`void gpuMain2<4>(...)`), so `^gpuMain` misses
  them. A reported "-k gpuMain stopped matching" regression was **not reproduced** at HEAD or at
  `13ca707`; the observed failure was a kernelDB/ROCM_PATH environment difference
  (`bf_kernel-filter-search`). Suite 24 pins the semantics.
- **No-match warning** (`b71927b`): at exit, if a `-k` filter matched none of the dispatched
  instrumented-capable kernels, stderr says `omniprobe: WARNING: no dispatched kernel matched the
  kernel filter -k '...'` and lists them — distinct from the "ran uninstrumented because no
  instrumented clone was found" summary.
- **A kernelDB scan failure no longer drops dispatches** (`c8e81c6`). Before, `scanCodeObject`
  threw inside `fixupPacket`, `doPackets`' catch skipped writing the packet, and the
  instrumented dispatch silently never ran (wrong results, exit 0). Now the scan failure is
  caught at the scan, reported once (`omniprobe: ERROR: kernelDB could not read ...`), counted in
  the exit summary, and the clone runs without source attribution. **Per-packet safety net:** any
  other exception while instrumenting a dispatch submits the original packet ("running it
  uninstrumented") instead of dropping it.
- **Faulted dispatches cannot hang exit** (`bf_faulted-dispatch-hang`). `signal_runner` used to
  loop on pending signals without checking `shuttingdown()`; a faulted kernel's completion signal
  never reaches 0, so `~hsaInterceptor`'s join blocked forever. Now, once shutdown starts, it
  keeps completing dispatches but **abandons the rest 3 s (`SIGNAL_SHUTDOWN_GRACE`) after the
  last completion** (or after shutdown began), with a warning naming each kernel. Abandoned
  dispatches get no report and their comms objects are leaked on purpose (buffers may hold a
  half-written message; the process is exiting). `getPendingSignals` now actually locks
  (`lock(mutex)` had declared a function).
- **Exit summary is one `write(2)`** after the thread joins. The observed split summaries were
  actually caused by the launcher interleaving stdout/stderr line by line (see `omniprobe-cli`);
  both fixes kept.
- kernelDB (submodule, unchanged) reads `ROCM_PATH` once at load and defaults to `/opt/rocm`; on
  nodes with only versioned `/opt/rocm-X.Y.Z` it fails unless `ROCM_PATH` is set — the launcher
  now sets it (`omniprobe-cli`).

## Invariants

- Singleton pattern (`hsaInterceptor::getInstance()`).
- Original HSA API preserved and callable via saved table.
- Signal runner thread waits on kernel completion signals.
- Shutdown sequence: set `shutting_down_` flag, join threads (signal runner gives up on pending dispatches after a 3 s grace), cleanup.
- A dispatch is never dropped: it runs instrumented, or uninstrumented with an error/warning.

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

**Fixed 2026-11-08 (`3e31ee8`, `8a3ea17`).** `demangleKernelName`
(`src/utils.cc`) gives both `.intern` hash flavours (letter- and digit-leading) the same decorated
demangled form and repairs the clone's misplaced `Pv`; `kernelDBName` gives handlers the name
kernelDB keyed the kernel under (kernelDB drops the last `.`-component of undemangleable names).
`getInstrumentedName` maps an empty parameter list to `(void, void*)`, because the clone of
`_Z1kv` is `_Z1kvPv`. `-cuid=<x>` pins the `.intern` hash, which is how the test fixture gets
both flavours (`a` → letter-leading, `c` → digit-leading). An end-of-run summary on stderr lists
kernels that ran without an instrumented clone (`__amd_rocclr_` blit kernels excluded).

## Open Questions

None.

## Last Verified

2026-03-24
2026-09-08 (data flow steps 4-5 rewritten for bf_hip-duplicate-code-object-load: app-loaded code objects are indexed rather than loaded into a private executable, and the -k filter now gates the clone swap at dispatch)
2026-09-08 (lookup-key scheme and its dependence on demangler success; measured)
2026-10-27 (mechanical re-check only: every file path and code symbol named in this unit exists in the tree; prose claims not re-read; no corrections)
2026-11-08 (demangler-key defects fixed; kernelDBName; uninstrumented-kernel summary; data-flow steps not re-read)
2026-11-08 (second session: -k regex semantics and no-match warning, kernelDB-failure and per-packet fallbacks, faulted-dispatch grace, one-write exit summary; verified by reading src/interceptor.cc signal_runner/abandonPendingSignals/runKernelInstrumented at 22c4d95 and the bf_* packets; data-flow steps 1-7 not re-read)

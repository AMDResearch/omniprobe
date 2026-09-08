# Handler Pipeline

## Responsibility

Manages the full handler lifecycle: loading handler plugins from shared libraries via a
factory interface, pooling `dh_comms` objects with checkout/checkin semantics, and attaching
handlers to dispatches. The interceptor uses this pipeline to efficiently reuse communication
resources across kernel dispatches.

## Key Source Files

| File | Purpose |
|------|---------|
| `src/comms_mgr.cc` | Pool implementation for dh_comms objects |
| `inc/comms_mgr.h` | `comms_mgr` class definition |
| `plugins/plugin.h` | Handler factory interface |
| `plugins/memory_analysis_plugin.cc` | MemoryAnalysis handler plugin |
| `plugins/logger_plugin.cc` | Message logger plugin |
| `plugins/basic_block_plugin.cc` | Basic block handler plugin |

## Key Types and Classes

| Type | Location | Purpose |
|------|----------|---------|
| `comms_mgr` | `inc/comms_mgr.h` | Pool manager for `dh_comms` objects |
| `getMessageHandlers_t` | `plugins/plugin.h:36` | Function pointer typedef for the factory function |

## Key Functions and Entry Points

| Function | Location | Purpose |
|----------|----------|---------|
| `comms_mgr::checkoutCommsObject()` | `inc/comms_mgr.h:59` | Get `dh_comms` for dispatch |
| `comms_mgr::checkinCommsObject()` | `inc/comms_mgr.h:60` | Return to pool |
| `comms_mgr::addAgent()` | `inc/comms_mgr.h:61` | Register new GPU agent |
| `getMessageHandlers()` | `plugins/plugin.h:32` | Plugin export — factory function returning handler instances |

## Data Flow

1. `handlerManager` reads `LOGDUR_HANDLERS` environment variable.
2. For each plugin path: `dlopen()`, lookup `getMessageHandlers` symbol.
3. `addAgent()` called when new GPU agent discovered.
4. `checkoutCommsObject()` creates new `dh_comms`, attaches handlers (custom via
   `LOGDUR_HANDLERS` or defaults: `memory_heatmap_t`, `time_interval_handler_t`).
5. Caller uses `dh_comms` for kernel dispatch.
6. `checkinCommsObject()` stops, reports, deletes handlers, then deletes `dh_comms` object.

### Built-in Plugins

| Plugin | Source | Handler |
|--------|--------|---------|
| libMemAnalysis64.so | `plugins/memory_analysis_plugin.cc` | `memory_analysis_handler_t` |
| libLogMessages64.so | `plugins/logger_plugin.cc` | `message_logger` |
| libBasicBlocks64.so | `plugins/basic_block_plugin.cc` | `basic_block_handler` |

## Invariants

- Plugins must export C function `getMessageHandlers()`.
- Handlers are instantiated per-dispatch (kernel name + dispatch ID).
- Plugin lifetime managed by `dlopen`/`dlclose`.
- No plugin versioning or compatibility checking exists.
- One pool per HSA agent.
- Checked-out objects tracked in `pending_comms_` map.
- Pool grows on demand via `growBufferPool()`.
- Thread-safe access via mutex.
- Configuration constants: `DH_SUB_BUFFER_COUNT=256`, `DH_THREAD_COUNT=1`,
  `DH_SUB_BUFFER_CAPACITY=256*1024`.

## Dependencies

- **interceptor** — usage context (interceptor checks out/in comms objects)
- **sub-dh-comms** — provides `message_handler_base` class and the objects being pooled

## Negative Knowledge

- **Handler lifetime is tied to the dh_comms object.** Do not store references to handlers
  across dispatches; they will be invalidated.
- **Passthrough wrapper classes removed:** `memory_heatmap_wrapper`,
  `memory_analysis_wrapper_t` were removed. Handlers are now instantiated directly. Do not
  re-introduce wrapper indirection.

## Negative Knowledge — `pythonMessageHandler` is broken *and* unreachable

`src/pyHandler.cc` contains `Py_Initialize`, `Py_Finalize` and `PyDict_New` and **no `PyGILState_*`
or `PyEval_*` call at all**. Messages arrive on a `dh_comms` worker thread, so the first
`PyDict_New()` segfaults. The destructor additionally calls `Py_Finalize()` — per instance, and a
handler is constructed per dispatch, so even with the GIL held it would tear down the process-wide
interpreter after the first kernel.

It has never run, because nothing can reach it. Verified 2026-09-08:

- constructed nowhere — `grep -rn pythonMessageHandler src/ inc/ plugins/` returns only its own
  definition and declaration;
- `inc/pyHandler.h:29` declares `class pythonMessageHandler {` with **no base class**, so
  `append_handler` cannot take it;
- `src/CMakeLists.txt:51` finds Python and `:107` adds its include dirs, but **nothing links
  `Python::Python`** — `liblogDuration64.so` carries 13 undefined `Py*` symbols and `ldd` shows no
  libpython. It links and loads only because nothing calls into it.

**Consequence for anyone testing it: the GIL fix cannot be verified in isolation.** There is no way
to get a message to the handler without also supplying reachability.

Tracked by `bf_pyhandler-gil`. The bridge ships as a **plugin**, not a core change — see
`pm-decisions.md`.

## Open Questions

None.

## Last Verified

2026-04-27 (merged from plugins + comms-mgr by pm-restructure)
2026-09-08 (pyHandler GIL defects and unreachability; verified by grep, nm and ldd)

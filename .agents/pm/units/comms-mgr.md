# Comms Manager

## Responsibility

Manages a pool of `dh_comms` objects and their associated resources (buffers,
memory managers). Provides checkout/checkin semantics so the interceptor can
efficiently reuse communication resources across dispatches.

## Key Source Files

| File | Purpose |
|------|---------|
| `src/comms_mgr.cc` | Pool implementation |
| `inc/comms_mgr.h` | `comms_mgr` class definition |

## Key Types and Classes

| Type | Location | Purpose |
|------|----------|---------|
| `comms_mgr` | `inc/comms_mgr.h` | Pool manager for `dh_comms` objects |

## Key Functions and Entry Points

| Function | Location | Purpose |
|----------|----------|---------|
| `comms_mgr::checkoutCommsObject()` | `inc/comms_mgr.h:58` | Get `dh_comms` for dispatch |
| `comms_mgr::checkinCommsObject()` | `inc/comms_mgr.h:59` | Return to pool |
| `comms_mgr::addAgent()` | `inc/comms_mgr.h:60` | Register new agent |

## Data Flow

1. `addAgent()` called when new GPU agent discovered.
2. `checkoutCommsObject()` creates new `dh_comms`, attaches handlers (custom via `LOGDUR_HANDLERS` or defaults: `memory_heatmap_t`, `time_interval_handler_t`).
3. Caller uses `dh_comms` for kernel dispatch.
4. `checkinCommsObject()` stops, reports, deletes handlers, then deletes `dh_comms` object.

## Invariants

- One pool per HSA agent.
- Checked-out objects tracked in `pending_comms_` map.
- Pool grows on demand via `growBufferPool()`.
- Thread-safe access via mutex.
- Configuration constants: `DH_SUB_BUFFER_COUNT=256`, `DH_THREAD_COUNT=1`, `DH_SUB_BUFFER_CAPACITY=256*1024`.

## Dependencies

- `interceptor.md` — usage context (interceptor checks out/in comms objects)
- Sub-project: dh_comms — the objects being pooled
- `plugins/` — handler loading for attaching to comms objects

## Negative Knowledge

- **Passthrough wrapper classes removed:** `memory_heatmap_wrapper`, `memory_analysis_wrapper_t` were removed. Handlers are now instantiated directly. Do not re-introduce wrapper indirection.

## Open Questions

None.

## Last Verified

2026-03-03

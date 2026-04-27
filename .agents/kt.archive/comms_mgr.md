# comms_mgr

## Responsibility
Manages a pool of `dh_comms` objects and their associated resources (buffers, memory managers). Provides checkout/checkin semantics so interceptor can efficiently reuse communication resources across dispatches.

## Core Concepts
- **Buffer Pool**: Pre-allocated dh_comms objects per agent
- **Checkout/Checkin**: Interceptor checks out object before dispatch, checks in after completion
- **Memory Pool Specs**: Per-agent memory pool info for HSA allocations
- **Handler Manager**: Loads and provides message handlers from plugins

## Key Invariants
- One pool per HSA agent
- Checked-out objects tracked in `pending_comms_` map
- Pool grows on demand via `growBufferPool()`
- Thread-safe access via mutex

## Data Flow
1. `addAgent()` called when new GPU agent discovered
2. `checkoutCommsObject()` creates new dh_comms, attaches handlers:
   - If custom handlers specified via `LOGDUR_HANDLERS`, uses those
   - Otherwise attaches default handlers: `memory_heatmap_t`, `time_interval_handler_t`
3. Caller uses dh_comms for kernel dispatch
4. `checkinCommsObject()` stops, reports, deletes handlers, then deletes dh_comms object

## Interfaces
- `comms_mgr(HsaApiTable*)` — constructor — `inc/comms_mgr.h:56`
- `checkoutCommsObject(agent, kernel_name, dispatch_id, kdb)` — get dh_comms — `inc/comms_mgr.h:58`
- `checkinCommsObject(agent, object)` — return to pool — `inc/comms_mgr.h:59`
- `addAgent(agent)` — register new agent — `inc/comms_mgr.h:60`
- `setConfig(config)` — apply configuration — `inc/comms_mgr.h:61`

## Dependencies
- dh_comms (the objects being created/destroyed per dispatch)
- HSA API (for memory allocation)
- Handler plugins (via handlerManager)
- Default handlers: `memory_heatmap_t`, `time_interval_handler_t` (from liblogDuration64)

## Also Load
- `interceptor.md` for usage context

## Configuration Constants
```cpp
#define DH_SUB_BUFFER_COUNT 256
#define DH_THREAD_COUNT 1
#define DH_SUB_BUFFER_CAPACITY (256 * 1024)
```

## Known Limitations
- Fixed sub-buffer count/capacity at compile time

## Recent Changes
- **2026-03-03**: Removed passthrough wrapper classes (`memory_heatmap_wrapper`, `memory_analysis_wrapper_t`)
  - Now instantiates wrapped handlers directly in `checkoutCommsObject()`
  - Simplified code: `comms_mgr.cc:80-81`

## Last Verified
Date: 2026-03-03

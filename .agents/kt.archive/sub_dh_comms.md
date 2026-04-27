# dh_comms (Sub-project Integration)

## Location
`external/dh_comms/` (git submodule)

## Sub-project KT
`external/dh_comms/.agents/kt/` (not yet initialized)

## Role in Omniprobe
Device-host communication library. Provides:
- Shared buffer infrastructure for streaming messages from GPU to host
- Message handler base class and chain mechanism
- Host-side polling thread for processing messages

## Integration Points

### Headers Used
- `dh_comms.h` — main API: `dh_comms` class, `dh_comms_descriptor`
- `message_handlers.h` — `message_handler_base` class
- `dh_comms_dev.h` — device-side functions (`v_submit_message`)

### Key Types
- `dh_comms::dh_comms` — orchestrates buffer allocation + message processing
- `dh_comms::dh_comms_descriptor` — struct passed to instrumented kernel
- `dh_comms::message_handler_base` — abstract handler class
- `dh_comms::message_t` — message structure

### Omniprobe Usage
1. `comms_mgr` pools `dh_comms` objects
2. Interceptor gets descriptor pointer via `get_dev_rsrc_ptr()`
3. Instrumented kernel receives descriptor as extra argument
4. Host calls `start()` before dispatch, `stop()` after completion
5. Handlers added via `append_handler()`

## Key Integration Invariants
- `dh_comms` objects must outlive kernel execution
- `stop()` must be called before destroying object
- Handler chain processed in order; first match wins

## Also Load
- Full sub-project KT at `external/dh_comms/.agents/kt/architecture.md` (when available)

## Last Verified
Date: 2026-03-02

# sub-dh-comms

## Responsibility

Device-host communication library (git submodule at `external/dh_comms/`). Provides shared buffer infrastructure for streaming messages from GPU to host, message handler base class, and host-side polling thread.

## Key Source Files

| File | Purpose |
|------|---------|
| `external/dh_comms/` | Git submodule root |
| `dh_comms.h` (within submodule) | Main API: `dh_comms` class, `dh_comms_descriptor` |
| `message_handlers.h` (within submodule) | `message_handler_base` class |
| `dh_comms_dev.h` (within submodule) | Device-side functions (`v_submit_message`) |
| `gpu_arch_constants.h` (within submodule) | L2 cache line sizes indexed by `gcnarch` enum |

## Key Types and Classes

| Type | Location | Purpose |
|------|----------|---------|
| `dh_comms::dh_comms` | `dh_comms.h` | Orchestrates buffer allocation + message processing |
| `dh_comms::dh_comms_descriptor` | `dh_comms.h` | Struct passed to instrumented kernel as extra argument |
| `dh_comms::message_handler_base` | `message_handlers.h` | Abstract handler class for processing messages |
| `dh_comms::message_t` | (internal) | Message structure for GPU-to-host data |

## Key Functions and Entry Points

| Function | Location | Purpose |
|----------|----------|---------|
| `dh_comms::start()` | `dh_comms.h` | Start message processing before dispatch |
| `dh_comms::stop()` | `dh_comms.h` | Stop message processing after completion |
| `dh_comms::get_dev_rsrc_ptr()` | `dh_comms.h` | Get descriptor pointer for kernel arg injection |
| `dh_comms::append_handler()` | `dh_comms.h` | Add handler to processing chain |

## Data Flow

1. `comms_mgr` pools `dh_comms` objects
2. Interceptor gets descriptor pointer via `get_dev_rsrc_ptr()`
3. Instrumented kernel receives descriptor as extra argument
4. Host calls `start()` before dispatch, `stop()` after completion
5. Handlers added via `append_handler()`

## Invariants

- `dh_comms` objects must outlive kernel execution
- `stop()` must be called before destroying a `dh_comms` object
- Handler chain processed in order; first match wins
- Use `git -C` for submodule git operations instead of `cd && git` (avoids security prompts)

## Dependencies

None (leaf submodule).

## Negative Knowledge

- Sub-project KT at `external/dh_comms/.agents/kt/` may not be initialized yet. Do not assume it exists.
- Use `git -C "$(git rev-parse --show-toplevel)/external/dh_comms"` for git operations in the submodule. Do not `cd` into the submodule directory and run `git` directly.

## Known Issues

- **Host-pinned alloc flag typo (`dh_comms.cpp:39`, latent):** the file hand-defines
  `static constexpr unsigned int hipHostMallocCoherent = 0x4;`, but in ROCm 7.2 `0x4` is
  actually `hipHostMallocWriteCombined` (real `hipHostMallocCoherent` = `0x40000000`).
  Introduced by commit `0c8a3635` (2026-06-01, dlsym refactor) when the `<hip/hip_runtime.h>`
  include was dropped and the constant re-transcribed by value. `0x4` (WriteCombined) is
  non-functional on AMD, so it silently falls back to a default pinned allocation. Confirmed
  **benign on MI350X/gfx950, ROCm 7.2** (2026-07-29): mid-kernel device↔host handshakes pass
  identically for `0x4`, `0x40000000`, and `0x0` (standalone test at
  `.untracked/coherence-test/`). Fix: set the value to `0x40000000`, or switch `calloc()` to
  `hipHostMallocUncached` (`0x10000000`, MTYPE_UC) to also avoid L2 pollution. See
  `.untracked/l2-cache-miss-investigation.md` and `.untracked/amd_gpu_memory_system.md`.

## Open Questions

None.

## Last Verified

2026-04-27 (re-verified; core content accurate, minor omissions noted but non-blocking)

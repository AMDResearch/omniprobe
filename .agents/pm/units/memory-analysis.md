# Memory Analysis

## Responsibility

Analyzes memory access messages from instrumented kernels. For global memory:
detects uncoalesced accesses by comparing actual cache lines used vs minimum
needed. For LDS: detects bank conflicts.

## Key Source Files

| File | Purpose |
|------|---------|
| `src/memory_analysis_handler.cc` | Handler implementation |
| `inc/memory_analysis_handler.h` | Handler class definition |

## Key Types and Classes

| Type | Location | Purpose |
|------|----------|---------|
| `memory_analysis_handler_t` | `inc/memory_analysis_handler.h:81` | Main handler class, inherits from `message_handler_base` |
| `conflict_set` | (defined in handler) | Group of lanes that may cause bank conflicts |

## Key Functions and Entry Points

| Function | Location | Purpose |
|----------|----------|---------|
| `memory_analysis_handler_t::handle(message)` | `inc/memory_analysis_handler.h:88` | Process single message (ISA context set via inherited `set_context()`) |
| `memory_analysis_handler_t::report()` | `inc/memory_analysis_handler.h:89` | Output analysis results |

## Data Flow

1. Receive `message_t` with address array (64 lanes) + DWARF info.
2. Determine memory type (global vs LDS) from address space.
3. For global: count cache lines, compare to minimum.
4. For LDS: compute bank conflicts using conflict sets.
5. Accumulate stats by source location.
6. On `report()`: output summary grouped by file/line.

## Invariants

- Cache line sizes are architecture-specific (`gfx906`/`908`: 64 bytes, `gfx90a`/`940`/`941`/`942`: 128 bytes) -- defined in `external/dh_comms/include/gpu_arch_constants.h`.
- Bank conflict analysis depends on access size:
  - 1/2/4 bytes: sets `{0..31}`, `{32..63}`
  - 8 bytes: 4 sets
  - 16 bytes: 8 non-contiguous sets
- ISA-level access size may differ from IR-level (`dwordx4` optimization).
- Output formats: Console, CSV (`LOGDUR_LOG_FORMAT=csv`), JSON (`LOGDUR_LOG_FORMAT=json`).

## Dependencies

- Sub-project: dh_comms — message types, handler base class, GPU architecture constants
- Sub-project: kerneldb — ISA instruction matching for access size correction

## Negative Knowledge

- **IR-level access size may not match ISA-level.** Always use kerneldb correlation to get correct sizes. Do not rely on the IR-level access width for cache line or bank conflict calculations.

## Open Questions

None.

## Last Verified

2026-04-27 (re-verified; fixed class/method line numbers, corrected handle() signature)

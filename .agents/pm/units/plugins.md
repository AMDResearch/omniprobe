# Plugins

## Responsibility

Provides a factory interface for loading message handlers from shared libraries. Handlers are loaded dynamically at runtime based on the `LOGDUR_HANDLERS` environment variable.

## Key Source Files

| File | Purpose |
|------|---------|
| `plugins/plugin.h` | Handler factory interface |
| `plugins/memory_analysis_plugin.cc` | MemoryAnalysis handler plugin |
| `plugins/logger_plugin.cc` | Message logger plugin |
| `plugins/basic_block_plugin.cc` | Basic block handler plugin |

## Key Types and Classes

N/A — C function-based plugin interface, no classes.

## Key Functions and Entry Points

| Function | Location | Purpose |
|----------|----------|---------|
| `getMessageHandlers()` | `plugins/plugin.h:32` | Plugin export — factory function returning handler instances |
| `getMessageHandlers_t` | `plugins/plugin.h:36` | Function pointer typedef for the factory function |

## Data Flow

1. `handlerManager` reads `LOGDUR_HANDLERS` environment variable
2. For each plugin path: `dlopen()`, lookup `getMessageHandlers` symbol
3. On dispatch: call factory function to get handler instances
4. Handlers appended to dh_comms handler chain

### Built-in Plugins

| Plugin | Source | Handler |
|--------|--------|---------|
| libMemAnalysis64.so | `plugins/memory_analysis_plugin.cc` | `memory_analysis_handler_t` |
| libLogMessages64.so | `plugins/logger_plugin.cc` | `message_logger` |
| libBasicBlocks64.so | `plugins/basic_block_plugin.cc` | `basic_block_handler` |

## Invariants

- Plugins must export C function `getMessageHandlers()`
- Handlers are instantiated per-dispatch (kernel name + dispatch ID)
- Plugin lifetime managed by `dlopen`/`dlclose`
- No plugin versioning or compatibility checking exists

## Dependencies

- **sub-dh-comms** — provides `message_handler_base` class. Also load: `sub-dh-comms.md`

## Negative Knowledge

- Handler lifetime is tied to the dh_comms object. Do not store references to handlers across dispatches; they will be invalidated.

## Open Questions

None.

## Last Verified

- 2026-03-02

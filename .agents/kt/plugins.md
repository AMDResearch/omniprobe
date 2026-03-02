# Plugin System

## Responsibility
Provides a factory interface for loading message handlers from shared libraries. Handlers are loaded dynamically at runtime based on `LOGDUR_HANDLERS` environment variable.

## Core Concepts
- **Handler Plugin**: A shared library exporting `getMessageHandlers()`
- **Handler Factory**: Function that creates handler instances for a kernel dispatch
- **Handler Chain**: Multiple handlers can be installed; first matching handler processes each message

## Key Invariants
- Plugins must export C function `getMessageHandlers()`
- Handlers are instantiated per-dispatch (kernel name + dispatch ID)
- Plugin lifetime managed by dlopen/dlclose

## Data Flow
1. `handlerManager` reads `LOGDUR_HANDLERS` env var
2. For each plugin path: `dlopen()`, lookup `getMessageHandlers` symbol
3. On dispatch: call factory function to get handler instances
4. Handlers appended to dh_comms handler chain

## Interfaces
- `getMessageHandlers(kernel, dispatch_id, outHandlers)` — plugin export — `plugins/plugin.h:32`
- `getMessageHandlers_t` — function pointer typedef — `plugins/plugin.h:36`

## Dependencies
- dh_comms (message_handler_base class)

## Built-in Plugins

| Plugin | Source | Handler |
|--------|--------|---------|
| libMemAnalysis64.so | `plugins/memory_analysis_plugin.cc` | memory_analysis_handler_t |
| libMessageLogger64.so | `plugins/logger_plugin.cc` | message_logger |
| libBasicBlockAnalysis64.so | `plugins/basic_block_plugin.cc` | basic_block_handler |

## Creating a Custom Plugin
1. Create .cc file with `getMessageHandlers()` implementation
2. Instantiate your handler(s), push to `outHandlers` vector
3. Build as shared library
4. Set `LOGDUR_HANDLERS=your_plugin.so`

## Known Limitations
- No plugin versioning or compatibility checking
- Handler lifetime tied to dh_comms object

## Last Verified
Date: 2026-03-02

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
| `plugins/python_bridge_plugin.cc` | PythonHandler plugin — adapter (`kdb_message_handler_base`) around `pythonMessageHandler` |
| `src/pyHandler.cc`, `inc/pyHandler.h` | `pythonMessageHandler` — calls a user Python module; compiled into the plugin only |
| `src/utils.cc` (`handlerManager::setHandlers`) | Plugin loading; `fatalHandlerError` |
| `inc/json_output.h` | `json_array_separator` — `[` vs `,` decided by output-file emptiness |

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
| `getMessageHandlers()` | `plugins/plugin.h` | Plugin export — factory function returning handler instances |
| `omniprobeValidateHandlers(std::string&)` | `plugins/plugin.h` | **Optional** plugin export, called once right after `dlopen`, before any kernel runs; `false` + message ends the run (PythonHandler uses it to import and check the module) |

## Data Flow

1. `handlerManager` reads `LOGDUR_HANDLERS` environment variable.
2. For each plugin path: `dlopen()`, lookup `getMessageHandlers` symbol, then call
   `omniprobeValidateHandlers` if exported. **Any failure is fatal** (`fatalHandlerError`,
   `src/utils.cc`): message `omniprobe: ERROR: ...` and `_exit(1)` — a `.so` that cannot be
   opened, lacks `getMessageHandlers`, or fails validation never falls back to the default
   handlers (`5b34ae3`).
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
| libBasicBlocks64.so | `plugins/basic_block_plugin.cc` | `basic_block_analysis` (`inc/basic_block_analysis.h`) |
| libPythonHandler64.so (`-a PythonHandler`) | `plugins/python_bridge_plugin.cc` | `python_bridge_handler_t` wrapping `pythonMessageHandler`; built only if CMake finds Python development files |

## Invariants

- Plugins must export C function `getMessageHandlers()`; `omniprobeValidateHandlers()` is optional.
- Handler-plugin load errors use `_exit(1)`, **not `exit(1)`**: `setHandlers` runs inside
  interceptor construction (`getInstance()` holding `singleton_mutex_`); `exit` ran rocprofiler's
  finalizer, which called omniprobe's tool finalizer, which waited on that mutex — the run hung
  (`-a <nonexistent .so>` hung until killed). Measured with gdb, 2026-11-08.
- **The core library `liblogDuration64.so` links no libpython** (`ldd`; 0 undefined `Py*`
  symbols). Only `libPythonHandler64.so` links `Python::Python` (`plugins/CMakeLists.txt`).
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

## PythonHandler (2026-11-08, `a5617d3`..`1434fa1`, `b9492cd`, `5b34ae3`)

User-facing: `omniprobe -i -a PythonHandler` with `OMNIPROBE_PYTHON_HANDLER` set to a `.py` path
(its directory is put on `sys.path`) or a module name importable through `PYTHONPATH`. Module
functions, all optional but at least one of the first three required (`inc/pyHandler.h`):

- `handleAddressWave(dict)` — once per wave per instrumented memory instruction: lane addresses,
  `lanes` (set bits of `exec`; left empty if their count disagrees with the addresses), exec
  mask, source file/line/column, access type, memory space, access size, block index, wave and
  CU/SE/XCC ids, timestamp. Added by `ft_pythonhandler-wave-fields`.
- `handleAddressMessage(dict)` — once per active lane, only `address` (the original form;
  unchanged so existing modules keep working). If both are defined, both are called.
- `handleTimeMessage(dict)` — start, stop, elapsed_time, block_id, source location, wave keys.
- `handleReport(dict)` — once per dispatch from the adapter's `report()`. Needed because the
  interpreter is never finalized, so Python `atexit` never runs.

Every dict carries `kernel` and `dispatch_id`. The API is **versioned by function name**: new
fields go into new or additively extended dicts, never by changing an existing function's
contract (`pm-decisions`).

Mechanism:

- **GIL**: every method that touches the C-API takes the GIL itself (RAII `gil_lock`); methods
  are called on dispatch, dh_comms processing and completion threads. `ensure_interpreter()`
  (`std::call_once`) starts the interpreter only if the host has none (Triton/PyTorch hosts are
  reused), with `Py_InitializeEx(0)`, then `PyEval_SaveThread()` so the starting thread does not
  keep the GIL.
- **The interpreter is never finalized.** Handlers are per dispatch, the interpreter per
  process; the old per-instance `Py_Finalize` killed it after the first dispatch. Deliberate
  leak at exit; process-lifetime teardown ownership is an open follow-up.
- Wrap, don't derive: `pythonMessageHandler` stays free of dh_comms types; the plugin's adapter
  derives from `kdb_message_handler_base` (so `source_file` resolves as in AddressLogger).
- Configuration errors (variable unset, module not importable, none of the functions defined)
  are fatal at load via `omniprobeValidateHandlers`; the launcher also checks unset / missing
  `.py` before starting.

Measured delivery behaviour (gfx90a, suite 19): **small kernels do not give concurrent delivery**
— each dispatch's messages are drained at completion, one dispatch at a time (0 overlaps over 32
dispatches on 4 streams). Only waves that fill their 256 KiB sub-buffer mid-kernel are processed
while the kernel runs, which is the only way several dh_comms threads call into Python at once.
A test of concurrent delivery must therefore use large per-wave message volumes.

Untested: PythonHandler inside a Python host (Triton). If the host thread holds the GIL while
blocking on kernel completion, completion (which joins the processing thread, which waits for the
GIL) could deadlock. Not measured.

## Output files and record integrity (2026-11-08)

- The CLI truncates the `-o`/`-l` file **once, before the run** (`cbac82a`); handlers only append.
- MemoryAnalysis and BasicBlockAnalysis JSON are one array per run: each record's prefix (`[` or
  `,`) comes from whether the file is empty, via `json_array_separator` in `inc/json_output.h`.
  The CLI finalizer appends `]` and warns if the result does not parse.
- Heatmap, AddressLogger and BasicBlockLogger JSON are **JSON Lines**, not arrays.
- Logger CSV contains only CSV rows (`ADDRESS_MESSAGE` / `WAVE_MESSAGE`); each kind's header is
  written with its first row (`f296bba`).
- Logger writes are serialized by a **process-wide mutex**: records from overlapping dispatches
  (each ≥1 KiB) interleaved without it (`de04bbd`).
- Handler console reports go to **stdout**, interceptor messages to **stderr** — the launcher
  forwards the target's streams verbatim (`2f60d83`).
- Known, unfixed: `-t json` without `-o` writes `results_<YYYY-mm-dd_HHMMSS>.json` in the cwd, so
  two runs started in the same second share a file.

## BasicBlockAnalysis semantics (2026-11-08, `093a6fe`, `2717c26`, `03c12f6`)

- **BBStart `user_data` is the IR basic-block ordinal (layout order). It does NOT correspond to
  kernelDB's ISA-derived blocks** — do not join the two.
- BBA keys blocks by `user_data` and takes file/line/column from the message header. The
  file-name hash is resolved against kernelDB's file names by
  `kdb_message_handler_base::sourceFileForHash`, which walks the line map, because basic-block
  instruction copies lack path ids in non-RDC builds.
- The BBStart plugin attributes a block to its first instruction that has a line, walked through
  `inlinedAt` to the kernel's own line.
- Reports `wave_visits` and `active_lanes`. **Timing was removed** (supervisor ruling, option 1):
  submit-to-submit `s_memtime` intervals measured instrumentation contention, not the block —
  median ~25k cycles at 16 waves vs 4–24M at 4096 waves. The BBInterval follow-up concluded
  2026-11-08 with **no timing analyzer**: BBInterval is experimental (see `instrumentation`).
- Non-BBStart messages are ignored with a once-per-process warning; MemoryAnalysis and Heatmap
  likewise warn once on non-address messages.

## Open Questions

None.

## Last Verified

2026-04-27 (merged from plugins + comms-mgr by pm-restructure)
2026-09-08 (pyHandler GIL defects and unreachability; verified by grep, nm and ldd)
2026-10-27 (mechanical re-check only: every file path and code symbol named in this unit exists in the tree; prose claims not re-read; basic_block_plugin handler corrected to basic_block_analysis)
2026-11-08 (output-file semantics and BBA semantics from this session's commits, verified on gfx90a; pyHandler section not re-verified, still resting on 2026-09-08)
2026-11-08 (second session: PythonHandler section replaces the 2026-09-08 'broken and unreachable' note; validation hook and fatal plugin-load errors; verified against src/pyHandler.cc, plugins/python_bridge_plugin.cc, plugins/plugin.h, src/utils.cc at HEAD 22c4d95 and the bf_pyhandler-gil / ft_pythonhandler-wave-fields / bf_robustness-errors packets; pool and output-file sections not re-read)

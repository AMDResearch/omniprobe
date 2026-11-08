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
- JSON schema (as of ft_omniprobe-python-api): flat per-access objects with `kernel`,
  `dispatch_id` at top level. Each access has `source_file`, `line`, `column`,
  `memory_space` ("global"/"lds"), `access_type`, `execution_count`, `excess_cache_lines`,
  `bank_conflicts`. Global accesses also have `cache_lines_needed`, `cache_lines_used`,
  `ir_bytes`, `isa_bytes`, `isa_instruction`. Metadata section with version, timestamp,
  gpu_info. Multi-dispatch output wrapped in JSON array by `finalize_json_output()` in CLI.
  *(Mechanism refined 2026-11-08: each record's `[`/`,` prefix comes from file emptiness via
  `inc/json_output.h`; the finalizer appends `]` — see `handler-pipeline`.)*
- Per-dispatch JSON also carries `unanalyzed_flat_accesses` and `unattributed_accesses` (no ISA instruction
  for the source line: all accesses when built without `-g`), each with a stderr line
  (`dab6433`, `7f826d1`). **Since 2026-11-08 `unanalyzed_flat_accesses` counts only waves whose
  lanes mix address spaces**: flat pointers are classified at run time by the AddressMessages
  plugin (`e807927`; see `instrumentation`), so `-O0` builds and pointers loaded from memory are
  analyzed like statically typed accesses (480 excess cache lines / 992 bank conflicts at both
  `-O0` and `-O2` in suite 21).
- ISA match (`4cd6f48`, `src/memory_analysis_handler.cc`): the size table includes
  `flat_load_*`/`flat_store_*`. Among ISA instructions at the same file/line/column the matcher
  **prefers one as wide as the IR access**, else the first match. Needed because at `-O0` the
  load of the pointer variable shares the access's line and column (an 8-byte
  `flat_load_dwordx2` was taken for a 4-byte access: 448 instead of 480 excess lines).
- LDS source files fall back to kernelDB names, so there are no split entries or
  `<unknown source file>`; an empty `source_file` on merged loads is fixed via the hash fallback.
- Dynamic LDS size is preserved on the instrumented dispatch (PR #40 `e7ca202`, clamp `cd58bed`).

### LDS bank-conflict model is per architecture, size and direction (2026-11-08)

`lds_model(arch)` in `src/memory_analysis_handler.cc`: for each access size, reads and writes
separately, a bank count and the lane groups served in one phase. **All measured** with
`tests/lds_conflict_sets/run.sh` (Rene's pairwise method: only lanes i and j hit one bank;
`SQ_LDS_BANK_CONFLICT` per dispatch; 256-byte stride = same bank for 32 or 64 banks, 128-byte only
for 32). The counter equals the handler's conflict count exactly (extra passes per wave per
instruction), so suite 26 (`tests/test_lds_bank_conflicts.sh`, 32 pattern kernels) demands equality.

| | gfx90a (CDNA1-3) | gfx950 (CDNA4, MI350X) |
|---|---|---|
| b32 r/w | {0..31},{32..63}, 32 banks | same |
| b64 read | 4 x 16 lanes, 32 banks | {0..31},{32..63}, **64 banks** |
| b64 write | 4 x 16 lanes, 32 banks | same as gfx90a |
| b128 read | {0..3,20..23},{4..7,16..19},{8..11,28..31},{12..15,24..27} (+32), 32 banks | {0..3,12..15,20..27},{4..11,16..19,28..31} (+32), **64 banks** |
| b128 write | 8 x 8 consecutive lanes, 32 banks | same as gfx90a |

The b128-write grouping was a bug until `8d7f35d` (the read grouping was applied to writes).
1- and 2-byte accesses are unmeasured and follow 4-byte. The model objects are allocated once and
never destroyed: function-local statics made omniprobe segfault at exit and lose the last dispatch
(the library is built with `-fno-threadsafe-statics`; handler threads outlive static destruction).

## Dependencies

- Sub-project: dh_comms — message types, handler base class, GPU architecture constants
- Sub-project: kerneldb — ISA instruction matching for access size correction

## Negative Knowledge

- **IR-level access size may not match ISA-level.** Always use kerneldb correlation to get correct sizes. Do not rely on the IR-level access width for cache line or bank conflict calculations.

## Open Questions

None.

## Last Verified

2026-07-20 (updated JSON schema documentation for ft_omniprobe-python-api)
2026-10-27 (mechanical re-check only: every file path and code symbol named in this unit exists in the tree; prose claims not re-read; no corrections)
2026-11-08 (new JSON counters, LDS name fallback, dynamic LDS; verified on gfx90a; cache-line and bank-conflict invariants not re-read)
2026-11-08 (second session: unanalyzed_flat_accesses now mixed-space waves only; flat_* ISA sizes and width-preferring match; from e807927/4cd6f48 and the ft_flat-address-classification packet, not re-measured; other invariants not re-read)
- 2026-11-08 (third session): LDS model section; suite 26 32/32 on gfx90a and on gfx950.

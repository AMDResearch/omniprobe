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
- Bank conflict analysis depends on the access class (gfx950: DS instruction; elsewhere access
  size and direction); see the LDS section below.
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

### LDS bank-conflict model is per DS instruction class (2026-11-09, branch lds-bank-model)

*Not on main yet (branch `lds-bank-model`, packet `iv_lds-bank-model`).* `lds_model(arch)` in
`src/memory_analysis_handler.cc` maps an **access class** to (bank count, lane groups per
cycle). On gfx950 (`lds_classes_from_isa`) the class comes from the **DS instruction** that
kernelDB finds at the access's file/line/column (`lds_isa_instruction`). The instruction is
read from the *original* kernel's ISA: the kdb name is the dispatched kernel object's
(`src/interceptor.cc:1156`). The clone's DS instructions differ, but its per-lane addresses
are the same, so pairing the clone's addresses with the original's class gives the
uninstrumented conflicts. Other architectures keep the 2026-11-08 size-based classes until
re-measured.

Measured with dh_comms `tools/lds_bank_probe` (`run_all.sh`; the model is `model.py`, and
the table is in the packet's `report-lds-2026-11-09.md`). gfx950 behaves as 64 banks for
`ds_read_b64`/`ds_read_b128`/the transpose loads and as 32 banks for everything else.

Classes:
- `narrow` (≤4 B, and each address of read2/write2_b32);
- `read_b64`, `read_b96`, `read_b128`;
- `write_b64` (also each address of read2/write2_b64), `write_b96`, `write_b128`;
- `read_b64_tr`, `read_b96_tr`;
- atomics: `atomic_b32`/`atomic_b64` (lanes on one address conflict),
  `atomic_cmpst_b32` (also mskor; 16 banks), `atomic_cmpst_b64` (8 lanes, 16 banks),
  `atomic_float` (float add is lane-serial and never a bank conflict: reported as
  `serialized_lanes`).

Rules:
- **Split IR access** (one wide IR access becomes a read2): counted per piece.
- **Merged on the same line:** counted once, at the access that starts the instruction.
- **Merged from another line:** the access has no DS instruction at its location. It is
  recorded with 0 and counted in per-dispatch `merged_lds_accesses`.
- **Flat accesses that reach LDS** (no DS instruction, but a `flat_*` there) keep the
  size-based class.
- **Atomics the compiler wave-reduced** (`v_mbcnt_*` at the location) count as one lane.

LDS atomics are instrumented by the plugin (atomicrmw/cmpxchg on addrspace 3, rw_kind
`read_write`). Suite 26 (`tests/test_lds_bank_conflicts.sh`, `tests/lds_bank_check.py`)
has 74 kernels, all equal to `SQ_LDS_BANK_CONFLICT` on gfx950. That needs the kernelDB
end_sequence fix (kerneldb branch `lds-bank-model`, not yet pushed; the patch is in the
packet). The model objects and regexes are allocated with `new` and never destroyed. A
function-local `static std::regex` segfaulted at exit: handler threads outlive static
destruction.

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
- 2026-11-09 (oplds, branch lds-bank-model): LDS section rewritten (per-instruction classes, atomics, kernelDB lookup); verified on gfx950 by suite 26 74/74.

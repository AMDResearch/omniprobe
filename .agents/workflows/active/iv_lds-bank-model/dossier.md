# Dossier — iv_lds-bank-model

## Metadata

- Workflow ID: iv_lds-bank-model
- Workflow Type: investigation (followed by a fix of the handler's LDS model)
- Lifecycle State: active
- Owner / Current Executor: oplds worker (supervised run, 2026-11-09), worktree `.untracked/wt-lds`, branch `lds-bank-model`
- Base Commit: 5d23a84 (omniprobe), 9551a41 (dh_comms)

```write-scope
external/dh_comms/tools/lds_bank_probe/
src/memory_analysis_handler.cc        (handler phase only, after both arches are measured)
inc/memory_analysis_handler.h         (handler phase only)
tests/lds_conflict_sets/, tests/test_lds_bank_conflicts.sh  (handler phase only)
.agents/workflows/active/iv_lds-bank-model/
```

## Objective

Rene, 2026-11-09: find out how LDS bank conflicts are counted on MI210 (gfx90a) and MI350
(gfx950), for reads and writes separately and for every access size the ISA supports, with
reusable pairwise-lane test code in dh_comms; tabulate; say where earlier assumptions were
wrong or incomplete; then fix the LDS analysis so it is right on both. The previous
gfx950 table ("32 banks for writes, 64 for some reads") is rejected as stated: a GPU has
one bank count. A single consistent model must explain all measurements.

## Hypotheses

- H1 (one physical layout): gfx950 LDS is 64 banks x 4 B. What differs between
  instructions is the datapath: a wide read path that can use all 64 banks per cycle, and
  a path for everything else that can use only one bank of each pair {b, b+32} per cycle
  (behaves as 32 banks). Status: behaviour **confirmed** [meas]; the pairing as the physical
  mechanism is [inf].
- H2: 32 banks x 8 B. **Refuted** [meas]: b32 reads at a 8-byte stride (lanes 0-31) conflict
  (1 extra cycle), which 8-byte banks cannot produce.
- H3: plain 32 x 4 B for everything. **Refuted** [meas]: b64/b128 reads of two lanes 128 B
  apart do not conflict; 256 B apart they do.

## Acceptance Criteria

- AC-1: reusable harness in dh_comms that measures, per DS instruction, lane groups and bank
  mapping from hardware counters, and checks a model against every measured pattern.
  **Met** (dh_comms `b3e2e8f`, `tools/lds_bank_probe/`).
- AC-2: gfx950 table for all ISA access classes, with a model that predicts
  `SQ_LDS_BANK_CONFLICT` exactly for every aligned measured pattern, including random
  patterns not used to build it. **Met** (172 runs, 109122 patterns, 0 mismatches).
- AC-3: same on gfx90a (MI210 node). Open.
- AC-4: handler's LDS model corrected/completed for both arches; suite 26 extended with the
  new classes (b96, read2/write2, sub-dword, atomics if instrumented) and failing on the
  current code. Open; after AC-3.

## Non-goals

Unaligned LDS accesses (they take another path, counted in `SQ_LDS_UNALIGNED_STALL`):
recorded, not modelled. LDS DMA (global_load_lds_*), ds_bpermute/permute/swizzle (no bank
access), GWS.

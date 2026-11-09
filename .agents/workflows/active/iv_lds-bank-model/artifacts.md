# Artifacts — iv_lds-bank-model

## Data

- Raw results, gfx950: `.untracked/lds-meas/gfx950-2026-11-09/` (res/*.json, model-check.txt,
  full.log); run `external/dh_comms/tools/lds_bank_probe/run_all.sh /tmp/x` to reproduce.
- ISA survey: `isa-survey.md` in this packet (subagent; llvm-mc assembled on both arches).

## gfx950 (MI350X), measured 2026-11-09 under /tmp/gpu-measure.lock

All [meas]: rocprofv3 per dispatch, SQ_LDS_BANK_CONFLICT / SQ_LDS_IDX_ACTIVE divided by
64 reps. "base" = cycles per instruction without conflicts (IDX_ACTIVE - BANK_CONFLICT,
identical for 1 lane and 64 lanes). "period" = bank function: two lanes of one group
conflict iff their addresses differ and are equal modulo this many bytes.

| class | instructions | lane groups (one per cycle) | period | base cycles | B/clk |
|---|---|---|---|---|---|
| narrow | read u8/i8/u16/d16/b32, write b8/b16/d16_hi/b32 | {0..31},{32..63} | 128 B (32 banks) | 2 | 128 (b32) |
| read b64 | ds_read_b64 | {0..31},{32..63} | **256 B (64 banks)** | 2 | 256 |
| read b128 | ds_read_b128 | {0..3,12..15,20..27},{4..11,16..19,28..31} (+32) | **256 B** | 4 | 256 |
| read b96 | ds_read_b96 | {0..3,20..23},{4..7,16..19},{8..11,28..31},{12..15,24..27} (+32) | 128 B | 8 | 96 |
| write b64 | ds_write_b64 | 4 x 16 consecutive | 128 B | 4 | 128 |
| write b96/b128 | ds_write_b96, ds_write_b128 | 8 x 8 consecutive | 128 B | 8 | 96/128 |
| read2/write2 b32 (+st64) | two narrow accesses | {0..31},{32..63}, each address | 128 B | 4 | |
| read2/write2 b64 (+st64) | two "write b64" accesses (also for read2!) | 4 x 16 consecutive | 128 B | 8 | |
| atomic 32 | ds_add_u32, ds_add_rtn_u32 | halves | 128 B, **same address conflicts** | 2 | |
| atomic 64 | ds_add_u64, ds_add_rtn_u64 | 4 x 16 consecutive | 128 B, same address conflicts | 4 | |
| tr b64 (gfx950) | ds_read_b64_tr_b4/b8/b16 | halves | 256 B | 2 | |
| tr b96 (gfx950) | ds_read_b96_tr_b6 | 4 x 16 consecutive | 256 B | 4 | |

Counting rule that reproduces every aligned pattern (model.py): per lane group, extra
cycles = max over banks of the number of distinct dwords the group touches in that bank,
minus 1; summed over groups (and over both addresses for read2/write2). Bytes in the same
dword never conflict (sub-dword broadcast), except atomics, which serialize every lane.

Other measured facts: misaligned accesses (u16 at odd, b64 at 4 mod 8, b96/b128 at
non-16) go to the unaligned path (SQ_LDS_UNALIGNED_STALL, e.g. b64 full wave 62 cycles),
with SQ_LDS_BANK_CONFLICT 0. A misaligned ds_add_u64 never completes (wave hang).
SQ_LDS_ADDR_CONFLICT is nonzero only for atomics on one address.

Consistency with the 2026-11-08 table: every set and "bank count" in it is reproduced;
they were bank-function periods of different datapaths, not different bank counts.

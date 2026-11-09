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

## Atomics spot-check (gfx950, 2026-11-09, under the lock)

Integer RMW (`ds_max_u32`, `ds_wrxchg_rtn_b32`, `ds_max_rtn_u64`) follow the add classes;
`ds_wrxchg2_rtn_b32` is two 32-bit atomic accesses. `ds_cmpst_rtn_b32` (two data dwords):
16 consecutive lanes per cycle, 64-byte period (behaves as 16 banks). Float atomics
(`ds_add_f32`, `ds_pk_add_f16`): SQ_LDS_BANK_CONFLICT is always 0; SQ_LDS_IDX_ACTIVE =
3 cycles per active lane whatever the addresses (lane-serial). All aligned patterns of
these seven ops match model.py. Data: `.untracked/lds-meas/gfx950-2026-11-09/atomics/`.
LDS atomics are not instrumented by the plugin (only LoadInst/StoreInst and buffer
intrinsics: src/instrumentation/AMDGCNSubmitAddressMessages.cpp:345-363), so the handler
never sees them.

## External check: ikl's blockmix (gfx950), predicted before reading their counters

model.py on their kernel (256 threads, 4 waves; per wave: 16 x gather read buf[P(pbox[t])],
reads/writes at P(t) and P(t^1)). Predicted per wave execution of the gather (:58):
shipped 14, control 0, pad i+(i>>4) 2 (both tables, and 2 on every other LDS access
too), pad i+(i>>5) shipped 1.75 (waves 1,2,2,2), control 0. Their measured values: 14.0,
0, 2.0, 2.0, 1.75, 0, and the kernel totals (224, 0, 100, 100, 28, 0 cycles per wave per
block) match exactly.
Why stride-17 padding fails: ds_read_b32/ds_write_b32 behave as 32 banks with 32-lane
groups. i+(i>>4) inserts a hole every 16 words, so the 32 consecutive words of a
half-wave span 33 dwords: the first and last land on the same bank -> every contiguous
access is 2-way (1 extra cycle per half, 2 per wave). i+(i>>5) inserts the hole every
32 words, which a 32-lane group never straddles. This is the same on gfx90a (b32 is
32 banks x 32 lanes there too), so the prediction for the MI210 is that i+(i>>4) is
also 2-way there, contrary to GROUND-TRUTH.md's "on gfx90a the expected best is
i+(i>>4)" [inf, to be measured].

## Handler (omniprobe 87d9363)

Access class from the DS instruction kernelDB finds at the access's file/line/column
(gfx950); size-based elsewhere. Suite 26: 58 kernels (26 new), omniprobe ==
SQ_LDS_BANK_CONFLICT for all on gfx950 [meas, lock]. On the unfixed handler (31d06c9) 13
of the new kernels differ (b96 unsupported; read2 b32/b64 counted with the b64/b128
classes; merged pairs counted as two 32-bank accesses).

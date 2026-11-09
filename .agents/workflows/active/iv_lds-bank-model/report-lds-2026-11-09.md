# LDS bank conflicts on MI350 (gfx950) and MI210 (gfx90a): how they are counted

Report for Rene, 2026-11-09. Worker `oplds`; branches `lds-bank-model` in omniprobe and
dh_comms (not merged to main). gfx90a column measured on an MI210 node, same day.

Tags: **[meas]** measured on hardware, with every GPU run under `/tmp/gpu-measure.lock`.
**[read]** read in code or docs. **[inf]** inference. **[ext]** external source.

## 1. Short answer

- **Your objection holds.** A GPU has one bank count, and the claim "gfx950 has both 32
  and 64 banks" was wrong as stated.
- **One model explains every measurement.** The LDS **behaves as 64 banks of 4 bytes**
  (bank = dword index mod 64) for `ds_read_b64`, `ds_read_b128` and the gfx950 transpose
  loads.
- For **every other access** it **behaves as 32 banks**. That covers all writes, reads of 4
  bytes or less, `ds_read_b96`, `ds_read2`/`ds_write2` and atomics. Put differently: banks
  b and b+32 are never both used in one cycle.
- So what the 2026-11-08 table called "banks" was the period of the bank function for two
  different datapaths, not two bank counts.
- **Why the two paths differ.** We see a wide read path at 256 B/clk and a 128 B/clk path
  for everything else [meas, via `SQ_LDS_IDX_ACTIVE`]. That fits the CDNA4 whitepaper,
  which says only *read* bandwidth doubled [ext].
- **What is measured and what is inferred.** Banks b and b+32 behaving as one bank on the
  128 B/clk path is [meas]. That they physically share a port is my interpretation [inf].
- **Fit.** One per-class model predicts `SQ_LDS_BANK_CONFLICT` exactly for all 109,122
  aligned patterns measured on gfx950. These include 300 random patterns per instruction
  that were not used to build the model. It also matched an independent kernel (ikl's
  blockmix, §5) in all six cases.
- **gfx90a (MI210)** [meas]: **32 banks for every access class**, no wide read path. It
  differs from gfx950 in exactly two classes: `ds_read_b64` (4 × 16 consecutive lanes,
  128 B period; gfx950: 2 × 32 lanes, 256 B) and `ds_read_b128` (the 8-lane b96 groups,
  128 B; gfx950: 4 × 16-lane groups, 256 B), and correspondingly those reads take twice the
  base cycles (4 and 8 vs 2 and 4). Every other class, atomics included, has the same lane
  groups and period on both. One model per architecture predicts `SQ_LDS_BANK_CONFLICT`
  exactly for all 140,257 aligned patterns measured on gfx90a (55 instructions; no
  transposes or `pk_add` on gfx90a).

## 2. Method (reusable, in dh_comms)

The tool is `external/dh_comms/tools/lds_bank_probe/`; its README has the details.

- **`lds_probe.cpp`** runs one exact DS instruction (inline asm) with arbitrary per-lane
  byte offsets. Inactive lanes are masked off, and each pattern is one dispatch.
- **`probe.py`** runs it under rocprofv3, under the GPU lock, with a kill timeout. It
  collects per dispatch, divided by the repetition count:
  - `SQ_LDS_BANK_CONFLICT`
  - `SQ_LDS_IDX_ACTIVE`
  - `SQ_LDS_ADDR_CONFLICT`
  - `SQ_LDS_UNALIGNED_STALL`
  - `SQ_INSTS_LDS`
- **Patterns per instruction:**
  - baselines: 1 lane, broadcast, and full/half/quarter waves at strides 4–256 B;
  - your pairwise method: all 2016 lane pairs, 512 B apart;
  - an address-delta sweep for lanes 0 and 1, which gives the bank function;
  - 300 random aligned patterns.
- **`model.py check`** compares the model's prediction with the measured counter for every
  pattern.
- **`run_all.sh`** runs the whole campaign. It takes about 5 minutes per GPU and covers 50
  instructions on gfx950.
- **A useful identity, always true [meas]:** `SQ_LDS_IDX_ACTIVE` = base cycles +
  `SQ_LDS_BANK_CONFLICT` + `SQ_LDS_UNALIGNED_STALL`. So the number of lane groups an
  instruction is served in can be measured directly.

## 3. The table

**Counting rule** (same for every class):
- Within each lane group, the extra cycles are the largest number of distinct dwords that
  one bank receives, minus 1. These are summed over groups, and over both addresses for
  read2/write2.
- Bytes in the same dword never conflict (sub-dword broadcast). Atomics are the exception:
  there every lane is served, even when lanes share one address.

**Columns:**
- "Groups" are the lanes served in one cycle.
- "Period" is the address delta at which two lanes of the same group hit the same bank:
  128 B behaves as 32 banks, 256 B as 64.
- "Base" is cycles per instruction without conflicts, for any number of active lanes.

| class | instructions | gfx950 groups | gfx950 period | gfx950 base | gfx90a (MI210) |
|---|---|---|---|---|---|
| narrow | read u8/i8/u16/i16 (+d16, d16_hi), b32; write b8/b16 (+d16_hi), b32 | {0..31},{32..63} | 128 B | 2 | same: 2 × 32 lanes, 128 B, base 2 [meas] |
| read b64 | `ds_read_b64` | {0..31},{32..63} | **256 B** | 2 | **4 × 16 consecutive lanes, 128 B**, base 4 [meas] |
| read b96 | `ds_read_b96` | {0..3,20..23},{4..7,16..19},{8..11,28..31},{12..15,24..27} (+32) | 128 B | 8 | same as gfx950 (8-lane groups, 128 B), base 8 [meas] |
| read b128 | `ds_read_b128` | {0..3,12..15,20..27},{4..11,16..19,28..31} (+32) | **256 B** | 4 | **the b96 groups (8 × 8 lanes), 128 B**, base 8 [meas] |
| write b64 | `ds_write_b64` | 4 × 16 consecutive lanes | 128 B | 4 | same, base 4 [meas] |
| write b96 | `ds_write_b96` | 8 × 8 consecutive lanes | 128 B | 8 | same, base 8 [meas] |
| write b128 | `ds_write_b128` | 8 × 8 consecutive lanes | 128 B | 8 | same, base 8 [meas] |
| read2/write2 b32 (+st64) | each of the two addresses is a narrow access | narrow | 128 B | 4 | same, base 4 [meas] |
| read2/write2 b64 (+st64) | each address is a **write b64**-class access, for reads too | 4 × 16 | 128 B | 8 | same (4 × 16, 128 B), base 8; here read b64 is the same class anyway [meas] |
| atomic 32-bit | integer add, max, wrxchg (rtn and no-rtn); **float min/max_f32**; wrxchg2 = 2 accesses | {0..31},{32..63}; one address conflicts | 128 B | 2 | same, base 2 [meas] |
| atomic 64-bit | add_u64, max_rtn_u64; **add_f64, add_rtn_f64, max_f64** | 4 × 16 | 128 B; one address conflicts | 4 | same groups and period; base 4, but **add_f64/add_rtn_f64 base 8** [meas] |
| atomic two-data 32 | `ds_cmpst(_rtn)_b32`, `ds_mskor(_rtn)_b32` | 4 × 16 | **64 B (16 banks)** | 4 | same (16 banks), base 4 [meas] |
| atomic compare-swap 64 | `ds_cmpst(_rtn)_b64` | 8 × 8 | **16 banks** | 8 | same (16 banks), base 8 [meas] |
| atomic float add | `ds_add(_rtn)_f32`; gfx950: `ds_pk_add(_rtn)_f16`, `ds_pk_add_bf16` | lane by lane, 3 cycles per active lane | never counted as a bank conflict | 3/lane | same for `ds_add(_rtn)_f32` (3 cycles/lane, never counted); pk_add n/a [meas] |
| transpose b64 (gfx950 only) | `ds_read_b64_tr_b4/b8/b16` | {0..31},{32..63} | 256 B | 2 | n/a |
| transpose b96 (gfx950 only) | `ds_read_b96_tr_b6` | 4 × 16 | 256 B | 4 | n/a |

Bandwidth implied by base cycles on gfx950 [meas]:
- b64 and b128 reads: 256 B/clk.
- b32 reads and every write: 128 B/clk.
- b96 read and b96 write: 96 B/clk. `ds_read_b96` takes 8 cycles against 4 for
  `ds_read_b128`, so b96 is not a cheaper b128.

**The unaligned path** [meas]: misaligned accesses never show in `SQ_LDS_BANK_CONFLICT`;
they cost `SQ_LDS_UNALIGNED_STALL` cycles. Examples: u16 at an odd byte, b64 at 4 mod 8,
b96/b128 not 16-byte aligned. A full wave of misaligned b64 reads costs 62 stall cycles.
A misaligned `ds_add_u64` never completes (the wave hangs), so the tool keeps atomics
aligned. The unaligned path is not modelled in Omniprobe.

**`SQ_LDS_ADDR_CONFLICT`** is nonzero only for atomics on a shared address [meas].

## 4. Where earlier assumptions were wrong or incomplete

1. **"32 and 64 banks on gfx950" (the 2026-11-08 table).** The lane groups and periods in
   it were reproduced. The *interpretation* was wrong: one layout, two datapaths (§1).
2. **The IR access size cannot pick the class.** Omniprobe's instrumentation works on IR,
   which knows only the access size. But on gfx950:
   - an 8-byte IR access may be `ds_read_b64` (64 banks) or `ds_read2_b32` (two 32-bank
     accesses);
   - a 16-byte one may be `ds_read_b128` or `ds_read2_b64`;
   - two 4-byte loads may be merged into one `ds_read_b64`.

   The handler now looks up the real DS instruction in kernelDB at the access's source
   location.
3. **12-byte accesses were unsupported.** The handler printed "not supported" for every
   one. They are now modelled. HIP's `float3` does not produce `ds_read_b96` (it becomes
   read2 + read); `ext_vector_type(3)` does.
4. **read2/write2 were unmodelled.**
   - read2_b32/write2_b32 are two narrow accesses, whatever the offsets.
   - read2_b64 behaves like two *write*-b64 accesses (16-lane groups, 32 banks), not like
     `ds_read_b64`.
5. **Sub-dword accesses** were assumed to follow 4-byte accesses. That is now measured and
   true, with dword-level broadcast.
6. **Atomics were not instrumented at all.** They now are, and they differ from reads and
   writes:
   - lanes on one address conflict;
   - compare-swap behaves as 16 banks;
   - float atomics are lane-serial and invisible to the conflict counter, so Omniprobe
     reports them as `serialized_lanes`, not as bank conflicts;
   - the compiler's atomic optimizer turns a uniform-address atomic into one lane's
     update. Omniprobe detects that from the ISA (`v_mbcnt` at the atomic's location).
7. **Stride-17 padding.** The textbook `i + (i >> 4)` pad leaves every contiguous b32
   access 2-way conflicted on gfx950: a 32-lane group spans 33 dwords and wraps onto one
   bank. `i + (i >> 5)` is conflict-free. Measured the same on gfx90a for read_b32 and
   write_b32: 2 and 0 cycles per wave [meas]; suite 26 now has both kernels.
8. **Original vs instrumented code** [read + meas]. The clone's DS *instructions* differ
   from the original's, but each lane's *address* is the same in both. The bank-conflict
   count depends on the addresses (from the clone's messages) and the instruction class
   (from the original's ISA). So pairing them gives the conflicts of the uninstrumented
   run, which is why the original's ISA is the right one to use.
   - The handler's kernelDB lookup uses the *original* kernel. The interceptor registers
     it under the dispatched kernel object's name (`src/interceptor.cc:1156`, `:983`).
   - The instrumented clones do have different DS code: they never merge loads, and they
     carry dh_comms' own LDS traffic.
   - The originals inside an instrumented binary have the same instruction stream as a
     plain build: 61 of 62 kernels identical, the other differing by one `v_cndmask`.
   - So Omniprobe reports the conflicts of the code that runs without instrumentation.

9. **kernelDB line attribution bug (pre-existing, found here)** [read + meas]. kernelDB
   mapped DWARF *end_sequence* rows as source locations
   (`external/kerneldb/src/addressMap.cc:347-351`). An end_sequence row carries the first
   address after a function, which usually equals the next function's first address. So
   the start of a function, up to its next line-table row, was attributed to the previous
   function's last line. The same-address check then dropped the real row.
   - On gfx950, `write_r2b64_stride8`'s `ds_write2_b64` instructions mapped to line 78
     instead of 121, which made Omniprobe report 0 conflicts against the hardware's 120.
   - Global accesses are matched through the same map, so they are affected the same way
     (they end up unattributed).
   - The fix is one check (skip end_sequence rows), on kerneldb branch `lds-bank-model`.
     It is not pushed yet; the patch is in this packet.

## 5. Validation

- **Suite 26** compares Omniprobe with `SQ_LDS_BANK_CONFLICT` on 74 pattern kernels. They
  cover 1/2/4/8/12/16-byte reads and writes, read2/write2, merged pairs (in a macro and on
  separate lines) and 12 atomic kernels. All 74 are equal on gfx950 with the kernelDB fix
  [meas]; without it, `write_r2b64_stride8` differs. Each new group
  of kernels fails on the code before its fix [meas]:
  - 13 kernels on `31d06c9` (12-byte accesses and read2/write2);
  - 2 on `87d9363` (merged accesses on separate lines);
  - 3 on `3c4b771` (atomics).
- **ikl's blockmix kernel** (independent, measured by ikl). This is a 256-thread
  transpose-like gather, and I predicted it with `model.py` before reading their counters:

  | case | predicted | ikl measured |
  |---|---|---|
  | shipped table | 14 | 14.0 |
  | control table | 0 | 0 |
  | pad `>>4`, shipped | 2 | 2.0 |
  | pad `>>4`, control | 2 | 2.0 |
  | pad `>>5`, shipped | 1.75 | 1.75 |
  | pad `>>5`, control | 0 | 0 |

  Values are cycles per wave execution of the gather. Kernel totals also match exactly.
- **Full regression suite** (gfx950 build of the branch): 23 passed, 3 skipped. The
  skipped suites need rocBLAS/hipBLASLt, which exist only for gfx90a.
- **gfx90a** (MI210, branch at `cf8d8e8` after merging main `f5a5721`) [meas]:
  - Suite 26 under the lock: 78 of 78 kernels equal (74 plus four padding kernels). On
    the handler before the gfx90a change, 21 of 74 differed: three b96, eight read2/write2, four
    merged-pair and five atomic kernels.
  - Full suite: 28 of 28 suites passed (27 in one run, plus suite 26 under the lock),
    including the rocBLAS/hipBLASLt suites.

## 6. What Nabu and the documentation say

- **Nabu**, asked via the supervisor with internal and org search on:
  - It could not verify the MI350 bank count, bank width, the read/write port widths, or
    the lane grouping.
  - Its only pointer was an internal design doc it cannot read:
    `//gfxip/gfx9/doc/mi350/design/SH/MI350_LDS.docx`.
  - With web search on, it quoted only the primary documents below.
  - Secondary sources (ROCm blogs, a shark-ai guide) say "64 banks × 4 B". That matches
    our wide-read path, but those sources say nothing about writes or narrow reads.
- **CDNA4 whitepaper:** "increasing the number of banks", read bandwidth doubled to
  256 B/clk [ext]. That is consistent with our measurements, and it mentions only reads.
- **CDNA3 ISA:** 32 banks × 4 B [read]. No local CDNA4 ISA document gives a bank count.
- **Open:** someone with access to `MI350_LDS.docx` could confirm or refute the physical
  interpretation in §1.

## 7. Still open

- **gfx908 and gfx942** are not measured. They keep the size-based class with the
  gfx90a geometry [inf].
- **add_f64 on gfx90a** takes 8 base cycles against 4 for other 64-bit atomics [meas];
  its conflict count follows the 64-bit atomic class exactly, so only the cost differs.
- **Atomics:** all kinds that exist on gfx950 are measured. `min_f64` is assumed to behave
  like `max_f64` [inf]. The `v_mbcnt` test for compiler wave-reduced atomics is a
  heuristic, but suite 26 checks it against hardware.
- **Flat accesses that reach LDS** (`-O0`) keep the size-based model; they are not
  measured per instruction.
- **Macros:** within a macro every access shares one source location. The handler then
  matches by access width, which can be ambiguous.

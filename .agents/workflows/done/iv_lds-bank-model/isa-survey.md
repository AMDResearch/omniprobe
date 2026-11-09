# LDS (DS) data-access instruction survey — gfx90a (CDNA2) vs gfx950 (CDNA4)

Date: 2026-11-09. Tags: **[read]** = read from a source file; **[meas]** = measured with a tool on this node.

## Sources and abbreviations

| Abbrev | Source |
|---|---|
| `DSI` | `/home1/rvanoo/repos/triton-3.9.0/triton/llvm-project/llvm/lib/Target/AMDGPU/DSInstructions.td` (LLVM 24-era, Triton 3.9.0 pin). Same file exists at `/home1/rvanoo/repos/sandbox/triton/llvm-project/...` (not diffed). |
| `ATD` | `.../AMDGPU/AMDGPU.td` (same tree) |
| `SIL` | `.../AMDGPU/SIISelLowering.cpp` (same tree) |
| `GST` | `.../AMDGPU/GCNSubtarget.cpp` (same tree) |
| `C3` | `/work1/amd/rvanoo/repos/omniprobe/.untracked/isa-mi300-text.txt` (CDNA3 ISA text, 26355 lines) |
| `C4X` | `/work1/amd/rvanoo/repos/rocjitsu/shared/machine-readable-isa/isa/amdgpu_isa_cdna4.xml` (CDNA4 machine-readable ISA; also `..._cdna2.xml` used for the diff). No CDNA4 PDF/text found locally. |
| `MC` | `/opt/rocm-7.2.0/llvm/bin/llvm-mc -arch=amdgcn -mcpu={gfx90a,gfx950} -show-encoding` (AMD LLVM 22.0.0git), one instruction per invocation. Input: `lds-isa-survey-probe/insts.s`; output: `lds-isa-survey-probe/results.txt`. |
| `HIP` | `/opt/rocm-7.2.0/bin/hipcc -O3 --offload-arch={gfx90a,gfx950} --cuda-device-only -S` on `lds-isa-survey-probe/k{,2,3}.hip` |

Presence columns below are from `MC` [meas] unless stated: every row marked `y` assembled with an encoding; every `n` gave `error: instruction not supported on this GPU`.

Instruction-set diff [meas, from `C4X` vs cdna2 XML `<InstructionName>DS_*`]: CDNA4 adds exactly `DS_PK_ADD_{F16,BF16}`, `DS_PK_ADD_RTN_{F16,BF16}`, `DS_READ_B64_TR_B{4,8,16}`, `DS_READ_B96_TR_B6` and `DS_READ_B128_TR_B6`; it drops the `DS_GWS_*` entries (but LLVM still assembles `ds_gws_init v0 gds` on gfx950 [meas]). `DS_READ_B128_TR_B6` (C4X:12973) is a duplicate of `DS_READ_B96_TR_B6` (same opcode 225, B96 operand, identical description) and `MC` rejects it on gfx950 [meas] — treat as an XML artifact.

**Spelling:** gfx950 keeps the GFX9 `ds_read_*`/`ds_write_*` spelling. `ds_load_b32`, `ds_store_b32`, `ds_load_tr8_b64` are rejected on both gfx90a and gfx950 [meas]; the `ds_load_*`/`ds_load_trN_*` aliases are GFX11+/GFX1250 only (DSI:1510-1517 [read]).

## Address semantics (applies to the whole table)

- Single address: `LDS_Addr = LDS_BASE + VGPR[ADDR] + {offset1,offset0}` (16-bit byte offset). Two addresses (read2/write2/wrxchg2): `Addr_k = base + VGPR[ADDR] + offset_k*ADJ`, where ADJ = 4 for ≤32-bit and 8 for 64-bit; `st64` variants multiply by 64 more (×256 B for b32, ×512 B for b64). C3:5990-6000, C3:18750-18759 [read].
- If `offset0 == offset1`, only one access happens and only DATA0 is used (C3:6003-6004 [read]). This matters for a test generator.
- The LDS is 32 banks × 4 B (CDNA3: C3:480, C3:5879-5886 [read]). The CDNA3 text says "extended instructions, read2/write2, can be 64-bits each" (C3:5884-5885 [read]). LLVM's `FeatureLDSBankCount32` is set for gfx90a and the gfx94x/950 common set (ATD:1904-1935, ATD:1928-1972 [read]), but that feature drives interpolation, not a CDNA bank model, so it is not evidence for gfx950. **I found no local source that gives gfx950's bank count or width.** gfx950 LDS is 160 KiB (`FeatureAddressableLocalMemorySize163840`, ATD:1975 [read]) versus 64 KiB on gfx90a.

## Survey table

Legend: B/addr = bytes per lane per address; #addr = addresses per lane; Dir: R = read, W = write, RMW = atomic read-modify-write. AGPR data forms (`a[...]`) exist on gfx90a+ (DSI:184, 210, 513 [read]; `ds_read_b32 a0, v10` and `ds_write_b128 v10, a[4:7]` assemble on both [meas]). They have the same memory behaviour as the VGPR forms.

### Indexed reads

| Instruction | B/addr | #addr | Dir | gfx90a | gfx950 | Notes |
|---|---|---|---|---|---|---|
| ds_read_u8 / ds_read_i8 | 1 | 1 | R | y | y | zero/sign-extended to a dword (C3:5965-5966). DSI:787-788 |
| ds_read_u8_d16 / _d16_hi | 1 | 1 | R | y | y | writes the low or high 16 bits of the VGPR and keeps the rest. `HasD16LoadStore` = GFX9Insts (DSI:777-783, ATD:2866-2867) |
| ds_read_i8_d16 / _d16_hi | 1 | 1 | R | y | y | as above, signed |
| ds_read_u16 / ds_read_i16 | 2 | 1 | R | y | y | DSI:766, 789 |
| ds_read_u16_d16 / _d16_hi | 2 | 1 | R | y | y | DSI:782-783 |
| ds_read_b32 | 4 | 1 | R | y | y | DSI:767 |
| ds_read_b64 | 8 | 1 | R | y | y | DSI:768 |
| ds_read_b96 | 12 | 1 | R | y | y | 3 consecutive dwords (C3:18966-18972). DSI:817 (isGFX7Plus) |
| ds_read_b128 | 16 | 1 | R | y | y | 4 consecutive dwords (C3:18973-18980). DSI:818 |
| ds_read2_b32 | 4 | 2 | R | y | y | offsets ×4. DSI:770 |
| ds_read2st64_b32 | 4 | 2 | R | y | y | offsets ×256 B. DSI:771 |
| ds_read2_b64 | 8 | 2 | R | y | y | offsets ×8 (C3:18740-18748). DSI:773 |
| ds_read2st64_b64 | 8 | 2 | R | y | y | offsets ×512 B (C3:18750-18759). DSI:774 |
| ds_read_addtid_b32 | 4 | 1 (implicit) | R | y | y | addr = `{off1,off0} + M0[15:0] + laneID*4`. No address VGPR, so lanes are always contiguous (C3:18902-18907). DSI:791-792 (`HasDSAddTid`, GFX9+) |
| ds_read_b64_tr_b4 | 8 | 1 | R | n | y | transpose load: 64 bits/lane treated as a 4-bit-element matrix and transposed across lanes (C4X:12928). wave64 only, `HasGFX950Insts` (DSI:922-923) |
| ds_read_b64_tr_b8 | 8 | 1 | R | n | y | 8-bit elements (C4X:13017). DSI:924 |
| ds_read_b64_tr_b16 | 8 | 1 | R | n | y | 16-bit elements (C4X:13060). DSI:925 |
| ds_read_b96_tr_b6 | 12 | 1 | R | n | y | 6-bit elements, 96 b/lane (C4X:12971). VGPR operand `AVLdSt_96_Align1` (DSI:926) |

### Indexed writes

| Instruction | B/addr | #addr | Dir | gfx90a | gfx950 | Notes |
|---|---|---|---|---|---|---|
| ds_write_b8 | 1 | 1 | W | y | y | DSI:611 |
| ds_write_b8_d16_hi | 1 | 1 | W | y | y | stores VGPR bits [23:16]. DSI:605 |
| ds_write_b16 | 2 | 1 | W | y | y | DSI:612 |
| ds_write_b16_d16_hi | 2 | 1 | W | y | y | stores VGPR bits [31:16]. DSI:606 |
| ds_write_b32 | 4 | 1 | W | y | y | DSI:597 |
| ds_write_b64 | 8 | 1 | W | y | y | DSI:659 |
| ds_write_b96 | 12 | 1 | W | y | y | C3:18946-18952. DSI:822 |
| ds_write_b128 | 16 | 1 | W | y | y | C3:18953-18960. DSI:823 |
| ds_write2_b32 / ds_write2st64_b32 | 4 | 2 | W | y | y | DSI:598-599 |
| ds_write2_b64 / ds_write2st64_b64 | 8 | 2 | W | y | y | DSI:660-661 |
| ds_write_addtid_b32 | 4 | 1 (implicit) | W | y | y | addr = `{off1,off0} + M0[15:0] + laneID*4` (C3:17727-17732). DSI:614-615 |

### Atomics and exchange (RMW). Each comes in a no-return form (`ds_X`) and a returning form (`ds_X_rtn`)

| Class / members | B/addr | #addr | Dir | gfx90a | gfx950 | Notes |
|---|---|---|---|---|---|---|
| 32-bit integer: add, sub, rsub, inc, dec, min/max_{i,u}32, and/or/xor_b32 | 4 | 1 | RMW | y | y | noret DSI:576-587; rtn DSI:668-683. Tested: ds_add_u32 and ds_add_rtn_u32 |
| 32-bit float: add_f32, min/max_f32 (+ _rtn) | 4 | 1 | RMW | y | y | add_f32 requires `HasLDSFPAtomicAddF32` (DSI:589-591, 670-672) |
| ds_pk_add_{f16,bf16} (+ _rtn) | 4 | 1 | RMW | **n** | y | 2×16-bit packed. `HasAtomicDsPkAdd16Insts`, gfx942+ (DSI:625-630, DSI "GFX942+" block ~2075) |
| 32-bit 2-operand: ds_mskor_b32, ds_cmpst_{b,f}32, ds_cmpstore_* (+ _rtn), ds_wrap_rtn_b32 | 4 | 1 | RMW | y | y | two data VGPRs but one address. wrap: C3:17967-17975. cmpstore_* is a GFX10+ spelling (DSI:632-639) and was not tested |
| ds_wrxchg_rtn_b32 | 4 | 1 | RMW | y | y | DSI:690 |
| ds_wrxchg2_rtn_b32 / ds_wrxchg2st64_rtn_b32 | 4 | 2 | RMW | y | y | two addresses (read2/write2 addressing). DSI:691-692 |
| 64-bit integer: add..xor_u/i/b64 (+ _rtn) | 8 | 1 | RMW | y | y | DSI:645-656, 694-705 |
| 64-bit float: min/max_f64, ds_add_f64 (+ _rtn) | 8 | 1 | RMW | y | y | add_f64: `HasLdsAtomicAddF64`, "GFX90A+" (DSI:620-623, ~2072) |
| 64-bit 2-operand: ds_mskor_b64, ds_cmpst_{b,f}64 (+ _rtn) | 8 | 1 | RMW | y | y | DSI:657, 663-664, 706-708 |
| ds_wrxchg_rtn_b64 | 8 | 1 | RMW | y | y | DSI:712 |
| ds_wrxchg2_rtn_b64 / ds_wrxchg2st64_rtn_b64 | 8 | 2 | RMW | y | y | DSI:713-714 |
| ds_condxchg32_rtn_b64 | 8 (2×4) | 1 | RMW | y | y | addr is forced 8-byte aligned (`& 0xfff8`); each dword is written only if its MSB is set (C3:18775-18793). DSI:810 |
| ds_append / ds_consume | 4 | 1, wave-uniform | RMW | y | y | addr = instr offset only (LDS); adds or subtracts popcount(EXEC) and returns the pre-op value (C3:18938-18945). One access per wave, so there is no lane-vs-lane conflict. DSI:797-798 |
| ds_*_src2_* | — | — | — | n | n | `HasDsSrc2Insts` is absent on GFX9 (DSI:726-759) [meas] |
| ds_ordered_count | — | — | — | n | n | `isNotGFX90APlus` (DSI:800-801) [meas] |

### Not LDS memory accesses (excluded from the bank model)

| Instruction | gfx90a | gfx950 | Notes |
|---|---|---|---|
| ds_swizzle_b32 | y | y | "does not read or write the DS memory banks" (C3:18038). `mayLoad = 0, mayStore = 0` (DSI:761-762) |
| ds_permute_b32 / ds_bpermute_b32 | y | y | cross-lane routing through the LDS crossbar; "Does not write any LDS memory" (C3:5981-5989). DSI:837-840. `__builtin_amdgcn_ds_bpermute` emits `ds_bpermute_b32` [meas HIP] |
| ds_gws_* | y | y | GWS, not LDS. Requires an even VGPR, so `ds_gws_init v1` fails and `v0` assembles [meas]. C3:6020-6022 |
| ds_nop | y | y | DSI:826 |

### Non-DS instructions that write LDS (out of scope for the DS bank model)

| Instruction | gfx90a | gfx950 | Notes |
|---|---|---|---|
| buffer_load_{dword,ubyte,...} ... lds | y | y | LDS DMA (`FeatureVMemToLDSLoad`, ATD:1628). `buffer_load_dword ... lds` assembles on both [meas] |
| buffer_load_dwordx4 ... lds (and x3) | n | y | gfx950 wide LDS-DMA [meas] |
| global_load_lds_{ubyte,dword,dwordx3,dwordx4} | n | y | gfx940+ form; x3/x4 are new in gfx950 [meas] |

## Alignment

- GFX9, which covers both targets, has `FeatureUnalignedDSAccess` (ATD:1627 [read]). For amdhsa, LLVM forces `+unaligned-access-mode` and `+enable-ds128` (GST:106, 111 [read]). So `hasUnalignedDSAccessEnabled()` is true (`GCNSubtarget.h:341-342` [read]), and LLVM will emit unaligned DS accesses. At runtime this depends on the hardware alignment mode (SH_MEM_CONFIG). That register's DS-specific behaviour is not documented in the local CDNA3 text, which only lists "LDS alignment error" as an exception source (C3:1041 [read]).
- LLVM lowering (SIL:2161-2260 [read]):
  - an 8-byte access needs only 4-byte alignment, because it is done with `ds_read2/write2_b32`;
  - a 16-byte access needs 8-byte alignment, because it is done with `ds_read2/write2_b64`;
  - b96 and b128 are "fastest when naturally aligned";
  - gfx8 and older required 16-byte alignment for b96/b128.
  - So a misaligned `float2`/`float4` may compile to read2/write2 instead of b64/b128. **A bank test should use naturally aligned addresses.**
- VGPR alignment: on gfx90a+, 64-bit-and-wider data operands must be even-aligned VGPRs (C3:897-898 [read]). `ds_read_b96_tr_b6` is the explicit exception (`Align1`, DSI:926).

## How to make hipcc emit each class (all [meas HIP] on both gfx90a and gfx950 unless noted)

| Class | Source construct → instruction |
|---|---|
| R1/W1 | `unsigned char`/`signed char` `__shared__` element → `ds_read_u8` / `ds_write_b8`. Sign-extending into an `int` gives `ds_read_i8` |
| R2/W2 | `unsigned short`/`short` → `ds_read_u16` / `ds_write_b16`. `short` → `int` gives `ds_read_i16` |
| R4/W4 | `float`/`int` → `ds_read_b32` / `ds_write_b32` |
| R8/W8 | `float2`/`double` → `ds_read_b64` / `ds_write_b64` |
| R12/W12 | `float __attribute__((ext_vector_type(3)))` → `ds_read_b96` / `ds_write_b96`. **HIP `float3` does NOT produce b96**: it gives `ds_read2_b32 + ds_read_b32` (align 4) |
| R16/W16 | `float4` → `ds_read_b128` / `ds_write_b128` |
| read2/write2 b32 | two loads from the same base: `s[i]` and `s[i+64]` → `ds_read2st64_b32` (offset ×256 B fits). Use small constant deltas for plain `read2`. Two stores 32 apart → `ds_write2_b32` |
| read2/write2 b64, st64 variants | inline asm, e.g. `asm volatile("ds_write2st64_b64 %0, %1, %2 offset0:0 offset1:1" :: "v"(a), "v"(x), "v"(y))` (gfx950 [meas]) |
| d16 / d16_hi | the compiler did not emit these for `_Float16` code (it used `ds_read_u16`/`ds_write_b16`). Use inline asm: `asm volatile("ds_read_u16_d16_hi %0, %1" : "=v"(r) : "v"(addr))` (gfx950 [meas]) |
| 32/64-bit atomics | `atomicAdd(&s[k], 1u)`, result unused → `ds_add_u32`; result used → `ds_add_rtn_u32`; `unsigned long long` → `ds_add_u64` |
| transpose (gfx950) | `__builtin_amdgcn_ds_read_tr{4,8}_b64_v2i32`, `__builtin_amdgcn_ds_read_tr6_b96_v3i32`, `__builtin_amdgcn_ds_read_tr16_b64_v4i16` (also v4f16/v4bf16, DSI:1387-1393) on an `address_space(3)` pointer → `ds_read_b64_tr_b{4,8,16}`, `ds_read_b96_tr_b6` [meas, gfx950 only] |
| addtid, wrxchg2, condxchg32, append | inline asm (M0 must be set for addtid; the compiler handles M0 for normal DS on GFX9 via `NotLDSRequiresM0Init`) |

In the inline asm, `addr` is a 32-bit LDS byte address: `(unsigned)(size_t)(__attribute__((address_space(3))) T*)&s[k]`.

## Distinct bank-behaviour classes

Grouping rule: same direction, same bytes per address, same number of addresses per lane, and same per-lane address freedom. The assumption is that the opcode suffix (signedness, d16 half, int vs float, which ALU op) does not change which banks are touched. That is a hypothesis to check once per class, not a documented fact.

| Class | Members | Minimal representative |
|---|---|---|
| R1 | read_u8, read_i8, read_{u8,i8}_d16{,_hi} | ds_read_u8 |
| R2 | read_u16, read_i16, read_u16_d16{,_hi} | ds_read_u16 |
| R4 | read_b32 | ds_read_b32 |
| R8 | read_b64 | ds_read_b64 |
| R12 | read_b96 | ds_read_b96 |
| R16 | read_b128 | ds_read_b128 |
| R2x4 | read2_b32, read2st64_b32 (only the offset scale differs) | ds_read2_b32 |
| R2x8 | read2_b64, read2st64_b64 | ds_read2_b64 |
| W1 | write_b8, write_b8_d16_hi | ds_write_b8 |
| W2 | write_b16, write_b16_d16_hi | ds_write_b16 |
| W4 / W8 / W12 / W16 | write_b32 / b64 / b96 / b128 | each one |
| W2x4 / W2x8 | write2{,st64}_b32 / write2{,st64}_b64 | ds_write2_b32, ds_write2_b64 |
| A4 | all 32-bit atomics (int, f32, pk_add_f16/bf16, mskor, cmpst, wrap, wrxchg_rtn_b32), noret and rtn | ds_add_u32 **and** ds_add_rtn_u32 (the return path may differ) |
| A8 | all 64-bit atomics incl. add_f64, cmpst_b64, wrxchg_rtn_b64, condxchg32_rtn_b64 | ds_add_u64 **and** ds_add_rtn_u64 |
| A2x4 / A2x8 | wrxchg2{,st64}_rtn_b32 / _b64 | ds_wrxchg2_rtn_b32, ds_wrxchg2_rtn_b64 (optional; rare in practice) |
| TR8 (gfx950) | read_b64_tr_b{4,8,16} | test all three: the element size may change how lanes are grouped, which is undocumented locally |
| TR12 (gfx950) | read_b96_tr_b6 | ds_read_b96_tr_b6 |
| fixed-pattern (no per-lane address) | read_addtid_b32, write_addtid_b32, append, consume | not needed in a pairwise test, because no lane can choose its own address |

**Minimal pairwise-lane test set** (both arches unless marked):

- Reads: `ds_read_u8`, `ds_read_u16`, `ds_read_b32`, `ds_read_b64`, `ds_read_b96`, `ds_read_b128`, `ds_read2_b32`, `ds_read2_b64`.
- Writes: `ds_write_b8`, `ds_write_b16`, `ds_write_b32`, `ds_write_b64`, `ds_write_b96`, `ds_write_b128`, `ds_write2_b32`, `ds_write2_b64`.
- Atomics: `ds_add_u32`, `ds_add_rtn_u32`, `ds_add_u64`, `ds_add_rtn_u64`.
- gfx950 only: `ds_read_b64_tr_b4`, `ds_read_b64_tr_b8`, `ds_read_b64_tr_b16`, `ds_read_b96_tr_b6`.

That is 20 instructions on gfx90a and 24 on gfx950. Optional spot checks to confirm the grouping assumption:

- `ds_read_i8` vs `ds_read_u8`, and one `_d16_hi`;
- `ds_read2st64_b32` with the same effective addresses as read2;
- `ds_wrxchg2_rtn_b32`;
- `ds_pk_add_f16` (gfx950) vs `ds_add_u32`.

For read2/write2/wrxchg2, the "pairwise" test must keep `offset0 != offset1`. Otherwise only one access is made (C3:6003).

## Open questions (not resolvable from local sources)

1. The gfx950 LDS bank count and width. CDNA4 LDS is 160 KiB; whether it is still 32 × 4 B banks is not in any local document.
2. How the transpose loads group lanes (which lanes cooperate on one matrix tile), and therefore what their effective bank footprint is.
3. Whether b64/b96/b128 are processed as half-wave or quarter-wave phases. C3 says only "Reads across wavefront are dispatched over four cycles in waterfall" (C3:5881-5882). This determines which lane pairs can conflict at all, and should be measured.

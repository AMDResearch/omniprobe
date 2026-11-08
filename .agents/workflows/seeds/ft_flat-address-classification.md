# Seed — `ft_flat-address-classification`

**Type:** `ft_` (feature)
**Filed:** 2026-11-08, by the opimpl worker (supervised run), at the supervisor's request ("scope it, don't do it now")
**Status:** seed — not yet a packet

## One line

Classify flat-pointer accesses as global, LDS or scratch **at run time on the device**, so
MemoryAnalysis analyzes them instead of only counting them (`unanalyzed_flat_accesses`,
`40a46b3`). Today every access in an `-O0` build, and every access through a pointer loaded from
memory, is flat and unanalyzed.

## What the code does today (read 2026-11-08)

- `src/instrumentation/AMDGCNSubmitAddressMessages.cpp:225-228`: the address space passed to
  `v_submit_address` is the IR pointer's static address space, a compile-time constant
  (`Builder.getInt8(AddrSpace)`), although the argument itself is a run-time `i8`.
- `external/dh_comms/include/dh_comms_dev.h:318-330`: `v_submit_address` packs it into the
  wave header's `user_data` (bits 2-5): **one value per wave message**, not per lane.
- `src/memory_analysis_handler.cc:226-250`: space 0 (flat) is counted and skipped; 1 (global) goes
  to the cache-line analysis, 3 (shared) to the bank-conflict analysis.
- The ISA size table (`memory_analysis_handler.cc:86-160`) has `global_*` and `ds_*` entries
  but no `flat_*` ones.

## Proposed design (inference, not prototyped)

In the plugin, for a flat pointer only:

1. Per lane: `is_shared = llvm.amdgcn.is.shared(p)`, `is_private = llvm.amdgcn.is.private(p)`.
2. Make it wave-uniform, because the space is per message: if all active lanes agree (compare
   ballots of `is_shared`/`is_private` with `exec`), pass that space (3, 5 or 1); if they disagree,
   keep 0 (flat) so the message is still counted as unanalyzed rather than misfiled.
3. For an LDS classification, submit the **LDS offset** (`addrspacecast` to addrspace 3, zero-
   extended), not the flat address: the bank-conflict analysis expects LDS offsets.
4. MemoryAnalysis: add `flat_load_*`/`flat_store_*`/`flat_atomic_*` to the ISA size table so the
   DWARF match finds the instruction for classified flat accesses.

## Acceptance criteria to write

- An `-O0` build of a kernel with a strided global access and an LDS bank-conflict pattern gives
  the same MemoryAnalysis findings (excess cache lines; bank conflicts) as its `-O2` build, with
  `unanalyzed_flat_accesses` = 0.
- A kernel that loads a pointer from memory and dereferences it gets cache-line analysis.
- A wave whose lanes mix spaces is still counted as unanalyzed (stays flat).
- Instrumentation overhead for non-flat accesses unchanged (no extra code emitted for them).

## Size and risk

**S–M.** One plugin function, a few intrinsics, a size-table extension, two test kernels.
Risks: `is.shared`/`is.private` availability and cost on each target (gfx90a, gfx942, gfx950;
check in LLVM for the pinned ROCm and Triton LLVMs); the Triton plugin variant must get the same
treatment; ballot/uniformity code inside a possibly divergent region must use `exec` correctly.

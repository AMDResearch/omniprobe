# Artifacts — ft_flat-address-classification (2026-11-08, gfx90a, ROCm 7.2.0)

- **Before** (HEAD plugin + handler, kernels recompiled): suite 21 → tests 1-3 FAIL
  (`-O0`: strided_read 32, transpose_no_pad 64, ptr_table 48 unanalyzed, no rows; `-O2`
  ptr_table read 16 unanalyzed, no row), test 4 PASS (guard).
- **After**: 4/4. `-O0` == `-O2`: strided read 480 excess cache lines, transpose read 992 bank
  conflicts; ptr_table read 480; mixed wave 1 unanalyzed at both levels. `-O0` rows match
  `flat_load_dword`/`flat_store_dword` (4 bytes).
- **AC-4**: `bank_conflict_test.cpp` (no flat accesses) compiled `-O3` with the HEAD plugin and
  with the new one: device instruction streams identical (8378 instructions, same hash).
- Not covered: gfx942/gfx950 (the intrinsics are generic AMDGPU; untested there); the Triton
  variant (same code, built; Triton kernels rarely use flat pointers, so the Triton suite does
  not exercise it).

# Dossier — ft_flat-address-classification

## Metadata

- Workflow ID: ft_flat-address-classification
- Workflow Type: feature
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Base Commit: 9dc29eb
- Seed: `.agents/workflows/seeds/ft_flat-address-classification.md`

```write-scope
src/instrumentation/AMDGCNSubmitAddressMessages.cpp
src/memory_analysis_handler.cc
tests/test_kernels/flat_access_test.cpp
tests/test_kernels/CMakeLists.txt
tests/test_flat_access.sh
tests/run_all_tests.sh
docs/usage.md
```

## Objective

MemoryAnalysis analyzes accesses through flat pointers instead of only counting them, so an
`-O0` build and an access through a pointer loaded from memory get the same findings as an
optimized, statically typed access.

## Design (decided 2026-11-08)

- **In the plugin, not in dh_comms.** The seed's plan. Classifying in dh_comms's
  `v_submit_address` would have served both plugin variants via the bitcode, but dh_comms is a
  submodule (separate repository) this run may not push to. The plugin change is compiled into
  both `-rocm` and `-triton` variants anyway.
- For a pointer whose address space is still flat after `stripPointerCasts()`: per lane
  `llvm.amdgcn.is.shared` / `is.private`, made wave-uniform with `llvm.amdgcn.ballot.i64`
  against `ballot(true)` (= the active lanes). All shared → 3, all private → 5, neither → 1,
  mixed → 0 (stays unanalyzed). Non-flat accesses emit exactly the code they did before.
- **No address conversion** (the seed proposed passing the LDS offset): the static LDS path
  already submits the flat address of an LDS location (aperture base + offset, e.g.
  `0x1000000000000`), so a flat pointer into LDS is already in the form the bank-conflict
  analysis receives.
- Also: when the accessed pointer itself is non-flat (a cast from flat), its own space is used.
- MemoryAnalysis: `flat_load_*`/`flat_store_*` added to the ISA size table. That exposed a
  matcher defect: at `-O0` the load of the pointer variable shares the access's line and column,
  so the first match (an 8-byte `flat_load_dwordx2`) was taken for a 4-byte access and the
  strided read reported 448 excess lines instead of 480. The matcher now prefers an instruction
  as wide as the IR access, else the first match as before.

## Acceptance Criteria

- **AC-1**: `-O0` build of a strided global read and an unpadded LDS transpose gives the same
  MemoryAnalysis findings as `-O2` (480 excess cache lines; 992 bank conflicts), with
  `unanalyzed_flat_accesses` = 0. (suite 21 tests 1-2)
- **AC-2**: a read through a pointer loaded from memory gets cache-line analysis (480, as the
  direct strided read). (suite 21 test 3)
- **AC-3**: a wave whose lanes mix LDS and global stays unanalyzed. (suite 21 test 4; a guard,
  passes before and after)
- **AC-4**: no extra code for non-flat accesses. (one-off check, artifacts.md)
- **AC-5**: full suite passes, 0 skipped.

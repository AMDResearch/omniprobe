# Workflow Dossier: rf_exact-arch-bitcode

## Metadata
- **Type**: refactor
- **State**: active
- **Owner**: unassigned
- **Created**: 2026-04-16 (migrated from KT)
- **Write Scope**: `src/instrumentation/InstrumentationCommon.cpp`, `tests/test_kernels/CMakeLists.txt`, `external/dh_comms/CMakeLists.txt`, `external/dh_comms/include/data_headers_dev.h`
- **Dependencies**: dh_comms PR #18 (merged 2026-04-15)
- **Failure Policy**: stop

## Objective
Replace the two-bucket (cdna2/cdna3) bitcode selection in instrumentation plugins with exact-architecture bitcode loading. Eliminates wave64/wave32 incompatibility preventing RDNA support.

## Non-Goals / Invariants
- No behavioral change for CDNA users
- No API changes
- No changes to dh_comms runtime library — only bitcode generation and selection

## Acceptance Criteria
1. Build: cmake --build build succeeds (gfx90a)
2. Tests: tests/run_all_tests.sh — all suites pass
3. Correctness: omniprobe -i -a MemoryAnalysis output unchanged vs baseline
4. File list: only exact-arch .bc files in build/lib/bitcode/, no cdna2/cdna3 files

## Plan of Record
1. Baseline: capture test output
2. Rewrite getBitcodePath() to try exact-arch first, fall back to cdna2/cdna3
3. Update copy_bitcode target for variable file list
4. Remove legacy cdna2/cdna3 generation from dh_comms CMakeLists.txt
5. Remove fallback path from getBitcodePath()
6. Extend dh_comms for RDNA (separate PR, may defer)
7. Run full test suite + compare output
8. Update PM

## Rejected Approaches
- Keep two-bucket model and add RDNA buckets — scales poorly
- Generate bitcode for all known architectures unconditionally — wasteful

## Open Questions
1. Does s_getreg_b32 hwreg(HW_REG_HW_ID) work on RDNA?
2. Should gcnarch enum be renamed to gpuarch?

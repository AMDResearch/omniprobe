# Workflow Dossier: rf_lazy-kerneldb-loading

## Metadata
- **Type**: refactor
- **State**: active
- **Owner**: unassigned
- **Created**: 2026-04-09 (migrated from KT)
- **Write Scope**: `src/interceptor.cc`
- **Dependencies**: kerneldb PR #27 (merged 2026-04-14)
- **Failure Policy**: stop

## Objective
Replace scanCodeObject() in interceptor.cc with addFile(lazy=true) so that kernelDB only disassembles the specific kernels that are actually dispatched, rather than every kernel in the code object.

## Non-Goals / Invariants
- No behavioral change in analysis output
- No API changes to omniprobe CLI
- No changes to coCache

## Acceptance Criteria
1. Build: cmake --build build succeeds
2. Tests: run_handler_tests.sh — all 25 handler tests pass
3. Tests: triton/run_test.sh — all 5 Triton integration tests pass
4. Correctness: Output of omniprobe -i -a MemoryAnalysis identical before and after

## Plan of Record
1. [done] Verify upstream prerequisites (PR #27 merged, all issues fixed, 30/30 tests pass)
2. [done] Survey coCache for code object path access (kernelDB::addFile() accepts .so paths)
3. Add lazy addFile calls at startup (after kernel_cache_.addFile in startup loop and addCodeObject path)
4. Remove scanCodeObject dispatch-time block (lines 802-808)
5. Run full test suite
6. Performance validation on hipBLASLt workload
7. Update PM

## Rejected Approaches
- Expose code object paths from coCache — unnecessary since kernelDB::addFile() handles extraction internally
- Dispatch-time-only addFile(lazy=true) — adds per-dispatch conditional; better to call at startup

# Active Workflows

This file coordinates concurrent work in `omniprobe`.

Packet directories follow the pattern: `.agents/workflows/<state>/<workflow-id>/`.

## Usage

- Add one row per active, suspended, blocked, failed, done, or abandoned workflow when that state matters for coordination.
- Keep intended write scope current.
- Check for overlap before multiple agents execute in parallel.

## Workflow Index

| Workflow ID | Type | State | Owner | Intended Write Scope | Dependencies / Overlap Notes | Blocker Status | Last Update |
|-------------|------|-------|-------|----------------------|------------------------------|----------------|-------------|
| rf_lazy-kerneldb-loading | refactor | active | unassigned | src/interceptor.cc | Overlaps with rf_rename-logduration (same file) | None | 2026-04-27 |
| rf_exact-arch-bitcode | refactor | active | unassigned | src/instrumentation/InstrumentationCommon.cpp, tests/test_kernels/CMakeLists.txt, external/dh_comms/ | None | None | 2026-04-27 |
| rf_rename-logduration-to-omniprobe | refactor | active | unassigned | src/, inc/, plugins/, omniprobe/, CMakeLists.txt, containers/, .github/ | Broad scope — overlaps with most other refactors | Open questions need user input | 2026-04-27 |
| rf_clang-format-consistency | refactor | active (blocked) | unassigned | .clang-format, CMakeLists.txt, scripts/git-hooks/ | None | Team coordination needed | 2026-04-27 |
| rf_test-organization | refactor | active | unassigned | tests/ | None | Design decisions needed | 2026-04-27 |
| ft_whitepaper-omniprobe | feature | active | unassigned | ~/repos/whitepaper_omniprobe/ | None (outside omniprobe repo) | None | 2026-04-27 |

## Completed (migrated from KT)

Completed refactors are archived in `.agents/kt.archive/refactors/done/` (19 completed).

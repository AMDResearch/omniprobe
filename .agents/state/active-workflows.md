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
| rf_lazy-kerneldb-loading | refactor | suspended | unassigned | src/interceptor.cc | Overlaps with rf_rename-logduration (same file) | None | 2026-08-25 |
| rf_exact-arch-bitcode | refactor | suspended | unassigned | src/instrumentation/InstrumentationCommon.cpp, tests/test_kernels/CMakeLists.txt, external/dh_comms/ | None | None | 2026-08-25 |
| rf_rename-logduration-to-omniprobe | refactor | suspended | unassigned | src/, inc/, plugins/, omniprobe/, CMakeLists.txt, containers/, .github/ | Broad scope — overlaps with most other refactors | Open questions need user input | 2026-08-25 |
| rf_clang-format-consistency | refactor | suspended | unassigned | .clang-format, CMakeLists.txt, scripts/git-hooks/ | None | Team coordination needed | 2026-08-25 |
| rf_test-organization | refactor | suspended | unassigned | tests/ | None | Design decisions needed | 2026-08-25 |
| ft_whitepaper-omniprobe | feature | suspended | unassigned | ~/repos/whitepaper_omniprobe/ | None (outside omniprobe repo) | Awaiting user review | 2026-08-25 |

**All six were suspended on 2026-08-25, and none of them was progressing.** Every packet's newest
file dated from 2026-04-27 or 2026-04-28 — four months dormant — while the table went on calling
them `active`, and four of the six already recorded a blocker needing human input (open questions,
team coordination, design decisions, awaiting review). `active` had stopped describing anything.

The immediate trigger was mechanical: `upgrade-project` refuses to migrate a repository with
anything under `.agents/workflows/active/`, because migrating template files mid-packet puts writes
nobody made inside a declared write scope and can flip an acceptance gate's verdict for reasons
unrelated to the work. But the state was wrong before the upgrade needed it fixed.

**Contracts are intact.** Nothing was completed, abandoned, or re-specified — the packets moved
directory and nothing inside them was edited. Resuming any of them is `/workflow-resume <id>`.
Note that two overlaps recorded above are still live and still matter on resume:
`rf_rename-logduration-to-omniprobe` has a broad scope that collides with most of the others, and
`rf_lazy-kerneldb-loading` shares `src/interceptor.cc` with it.


## Completed

| ID | Type | Completed |
|----|------|-----------|
| rf_triton-v3.7-bump | refactor | 2026-07-13 |
| ft_omniprobe-python-api | feature | 2026-07-20 |

## Completed (migrated from KT)

Completed refactors are archived in `.agents/kt.archive/refactors/done/` (19 completed).

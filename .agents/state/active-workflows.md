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
| bf_hip-duplicate-code-object-load | bugfix | **active** | unassigned | src/utils.cc, inc/utils.h, src/interceptor.cc, tests/, docs/ | **Collides with rf_lazy-kerneldb-loading** — see note below. Also shares src/interceptor.cc with rf_rename-logduration | None blocking start. AC-4/AC-5 need TRITON_DIR + INSTRUMENTED_ROCBLAS_LIB_DIR before they can be satisfied | 2026-09-08 |

### bf_hip-duplicate-code-object-load invalidates part of rf_lazy-kerneldb-loading's premise

**Promoted `draft/` → `active/` on 2026-09-08** after `/workflow-readiness-check` returned READY
with no structural failures. Base commit stamped at `74c6ed2`. It is now the only active workflow
in this repository, and it holds `src/interceptor.cc` — which is what makes the collision below
live rather than hypothetical.

Filed 2026-09-08 from a defect found on 2026-09-01 while profiling PENNANT: for a HIP fat binary
Omniprobe loads a **second, private copy** of every code object the process already has mapped,
and clones dispatched out of it read `__device__`/`__constant__` globals as **zero**. The failure
is silent — the run completes and produces empty-but-plausible analysis output.

This matters for coordination, not just as a new row. `rf_lazy-kerneldb-loading`'s plan step 4 is
*"Remove scanCodeObject dispatch-time block (lines 802-808)"* — the exact block that primes the
kernelDB and that the only known workaround for this defect depends on — and its invariants
declare *"No changes to coCache."* Both were written in April, before any of this was known.
**Do not resume `rf_lazy-kerneldb-loading` without reading
`draft/bf_hip-duplicate-code-object-load/dossier.md` first**; the two need to be sequenced, and
the older packet's contract may need revisiting.

`rf_exact-arch-bitcode` is adjacent but distinct: it covers the `gfx950` → CDNA2-bitcode
misselection surfaced by the same session, and its non-goal *"No changes to dh_comms runtime
library"* may not stretch to adding the missing `gfx950` enum.

**All six of the packets above were suspended on 2026-08-25, and none of them was progressing.** Every packet's newest
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

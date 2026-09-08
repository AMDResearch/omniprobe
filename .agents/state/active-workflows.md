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
| bf_intern-clone-name | bugfix | active | unassigned | src/utils.cc, src/instrumentation/InstrumentationCommon.cpp, src/instrumentation/include/InstrumentationCommon.h, tests/ | Overlaps rf_exact-arch-bitcode (same InstrumentationCommon.cpp) — that packet is suspended, so not a live collision; do not run both at once | None | 2026-09-08 |
| bf_exit-status-not-propagated | bugfix | active | unassigned | omniprobe/omniprobe, omniprobe/api/omniprobe.py, tests/ | Shares tests/run_all_tests.sh with bf_intern-clone-name and bf_pyhandler-gil — append-only, one run_suite line each | None | 2026-09-08 |
| bf_pyhandler-gil | bugfix | active | unassigned | src/pyHandler.cc, inc/pyHandler.h, plugins/, omniprobe/config/analytics.py, tests/ | Shares tests/run_all_tests.sh with the two above — append-only. Needs a GPU and an arch-matched build | None | 2026-09-08 |

### rf_lazy-kerneldb-loading's premise is invalidated — read this before resuming it

`bf_hip-duplicate-code-object-load` completed 2026-09-08 (packet in `done/`). Its fix stays live
in the tree and it invalidates part of an older packet's contract, so the note outlives it.

`rf_lazy-kerneldb-loading`'s plan step 4 is *"Remove scanCodeObject dispatch-time block (lines
802-808)"* and its invariants declare *"No changes to coCache."* Both were written in April.
Since then: `-k` no longer gates what `coCache` records, `kernel_co_map_` is populated for every
kernel in an indexed code object, and application-loaded code objects are indexed rather than
loaded into a private HSA executable. **"No changes to coCache" is now straightforwardly false of
the tree that packet would be resumed against.** The `scanCodeObject` block is no longer
load-bearing for the old `-k` workaround — there is no workaround any more — but it *is* still
load-bearing for DWARF correlation, so deleting it is not the free win the plan assumed.

**Revisit that contract before execution, not during.** Start from
`done/bf_hip-duplicate-code-object-load/dossier.md`.

`rf_exact-arch-bitcode` is adjacent but distinct: it covers the `gfx950` → CDNA2-bitcode
misselection surfaced by the same PENNANT session, and its non-goal *"No changes to dh_comms
runtime library"* may not stretch to adding the missing `gfx950` enum.

**Filed 2026-09-08 as `bf_intern-clone-name`** (active): the `.intern.<hash>` clone-name defect
that breaks `getInstrumentedName` (`src/utils.cc:117`). It was an explicit non-goal of the
completed packet. The pre-packet probe confirmed the framing and then went past it — the defect
is **intermittent at ~37.5% per translation unit**, decided by whether the compiler's content
hash begins with a hex letter, and the other ~62.5% work only because two independent defects
cancel. PENNANT is *not* needed; a three-kernel in-repo fixture reproduces both arms. Read the
packet's `dossier.md` § Background before touching either file.

### Three active bugfixes, and the order they should be taken in

All three were promoted 2026-09-08 and none has had any production code written for it.

Two of them — `bf_exit-status-not-propagated` and `bf_pyhandler-gil` — arrived as seeds from an
agent working in the **IntelliKit sidecar**, whose W5 extensibility spike found them against
pinned git objects of this repository. **IntelliKit depends on both fixes**, so the owner's
direction (2026-09-08) is to take them **before** `bf_intern-clone-name`, in fresh sessions.

They are independent of each other and can be done in either order, with one asymmetry worth
knowing: `bf_pyhandler-gil`'s AC-4 has to check the instrumented target's *own* exit status
rather than omniprobe's, precisely because `bf_exit-status-not-propagated` is unfixed. Doing the
exit-status packet first lets that check be simplified; doing it second costs nothing.

`bf_exit-status-not-propagated` needs **no GPU** — its targets are `/bin/sh` stubs — so it can run
on any node. `bf_pyhandler-gil` needs a GPU and an architecture-matched build.

**The one shared file is `tests/run_all_tests.sh`**, declared in all three write scopes on
purpose. Each packet appends only its own `run_suite` line and edits no other. Executed in
separate sessions as intended, that is append-only and conflict-free.

**All six of the suspended packets above were suspended on 2026-08-25, and none of them was progressing.** Every packet's newest
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
| bf_hip-duplicate-code-object-load | bugfix | 2026-09-08 |

## Completed (migrated from KT)

Completed refactors are archived in `.agents/kt.archive/refactors/done/` (19 completed).

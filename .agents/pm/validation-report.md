# PM Validation Report

**Date:** 2026-10-27
**Status:** ISSUES FOUND

Index and disk agree: 10 units listed, 10 unit files present, no orphans, no placeholder units.
No index entries were auto-healed. All units mentioned in `pm-current-state.md` exist.

## Schema Violations
- testing -- missing sections: Related Workflows (type `infra`; all other infra sections present)
- architecture -- type `arch-overview`: subsystem table present (`## Subsystems`), but no explicit
  loading guidance; `## Dependencies` lists units without saying when to load them. Minor.

Declared types match section structure for all 10 units (9 code-nav/arch layouts, 1 infra layout).

## Broken Anchors
- build-system :: `src/instrumentation/CMakeLists.txt` -- does not exist and never existed in git
  history (`git log --all` is empty for that path). Instrumentation plugins are built by
  `cmake_modules/add_instrumentation_plugins.cmake`.

Not counted as broken, but imprecise: sub-dh-comms lists `dh_comms.h`, `dh_comms_dev.h`,
`message_handlers.h`, `gpu_arch_constants.h` and sub-kerneldb lists `kernelDB.h` as bare names
"within submodule". All exist, under `external/dh_comms/include/` and `external/kerneldb/include/`.

Anchor check covered `Anchors / References` (infra) and `Key Source Files` (code-nav) sections.

## Stale Units
Threshold: 30 days; most recent `Last Verified` date taken as the maximum date in the section.
- architecture -- last verified: 2026-04-27
- sub-dh-comms -- last verified: 2026-04-27
- memory-analysis -- last verified: 2026-07-20
- handler-pipeline -- last verified: 2026-09-08
- interceptor -- last verified: 2026-09-08
- sub-kerneldb -- last verified: 2026-09-08

Fresh: build-system, instrumentation, testing (2026-10-27); omniprobe-cli (2026-10-26).

## Dangling Workflow References
None. No unit has a Related Workflows section; every workflow ID mentioned anywhere in a unit
body matches a packet directory under `.agents/workflows/`.

## Resolution (same day, 2026-10-27)

- build-system anchor: phantom `src/instrumentation/CMakeLists.txt` row replaced by `src/instrumentation/*.cpp`, with a note that the plugins build via `add_instrumentation_plugins.cmake`.
- testing: `## Related Workflows` added.
- architecture: loading guidance added after the subsystem table.
- Six stale units: mechanically re-checked (every named path and code symbol exists in the tree) and dated. Three corrections fell out — `handler-pipeline` named a non-existent `basic_block_handler` (it is `basic_block_analysis`), and `sub-dh-comms`/`sub-kerneldb` described a submodule KT that never existed (both submodules have their own `.agents/` tree). Prose claims in those six units were **not** re-read; the dates record a name-level check, not a semantic one.

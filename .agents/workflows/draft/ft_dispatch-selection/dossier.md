# Dossier: ft_dispatch-selection

## Metadata

- Workflow ID: ft_dispatch-selection
- Workflow Type: feature
- Lifecycle State: draft
- Owner / Current Executor: opdisp (worker), supervised
- Intended Write Scope:
- Dependencies On Other Active Workflows: none active. Overlaps `rf_rename-logduration-to-omniprobe`
  (suspended) on the `LOGDUR_DISPATCHES` name, which this packet keeps.
- Base Commit: (unstamped — set at promotion)

Tentative scope; fixed once the syntax is ruled on.

```write-scope
omniprobe/omniprobe
omniprobe/api/omniprobe.py
src/utils.cc
inc/utils.h
src/interceptor.cc
inc/interceptor.h
tests/
docs/usage.md
docs/triton-instrumentation.md
README.md
```

## Objective

Replace `-d all|1|random` with dispatch selection by per-kernel dispatch number — lists, inclusive
ranges and repeat shorthands — combined with the existing `-k` regex so that numbers count per
matching kernel; remove `-d random`. Source: Rene, `rene-response-2026-11-09.md` § Omniprobe.

## Background / Context

Survey of the current code paths, semantics, syntax options and recommendations:
[design.md](design.md). Phase 1 (this draft) is design only; the supervisor rules on the options
in design.md § 5 before any code is written.

## Contract

To be written after the ruling.

## Acceptance Criteria

To be written after the ruling. Planned shape: a grammar table (valid specs → expected set prefix,
invalid specs → expected error) run against the launcher and the runtime parser; a GPU test with
two kernels launched N times each asserting exactly which per-kernel ordinals ran instrumented for
`-d 2,5`, `-k A -d 2,5`, `-d 1,3,4:3`, `-d 1,3,4:3:100` (scaled), `-d 1::k`; `-d random` rejected
with the replacement hint; suite 27 replaced. Each check must fail on the current tree.

## Open Questions

design.md § 5, Q1–Q10.

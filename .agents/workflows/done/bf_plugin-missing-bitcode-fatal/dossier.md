# Dossier — bf_plugin-missing-bitcode-fatal

## Metadata

- Workflow ID: bf_plugin-missing-bitcode-fatal
- Workflow Type: bugfix
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Base Commit: 4d3242d2b9b8c7c0a01b8c6dd49777d1393a0d1a
- Dependencies On Other Active Workflows: none; `rf_exact-arch-bitcode` builds on it

```write-scope
src/instrumentation/InstrumentationCommon.cpp
tests/test_build_tree_bitcode.sh
tests/triton/run_test.sh
```

## Objective

A pass plugin that cannot load and link its device bitcode stops the compilation with a message
naming the missing file and the target arch, for HIP (hipcc) and Triton (JIT) alike.

## Background

Found 2026-11-08 while fixing the build-tree bitcode layout (`31eb907`): all three passes
`return false` when `loadAndLinkBitcode` fails (`AMDGCNSubmitAddressMessages.cpp:272`,
`AMDGCNSubmitBBStart.cpp:108`, `AMDGCNSubmitBBInterval.cpp:64`); hipcc exits 0 with an
uninstrumented binary. Supervisor ruling: standalone packet, hard error, Triton fails loudly
too; an opt-out may be proposed, not added.

## Acceptance Criteria

- **AC-1**: hipcc with a plugin whose bitcode is absent exits non-zero, produces no binary, and
  the error names the bitcode path and the target arch (suite 13, last test). Unfixed: rc 0,
  binary produced.
- **AC-2**: a Triton JIT compile with such a plugin exits non-zero naming the missing bitcode
  (Triton suite test 6). Unfixed: rc 0.
- **AC-3**: normal builds unaffected: suite 13 build-tree tests, all instrumented suites; full
  suite 16/16.

## Non-Goals

Arch detection for Triton modules (reports "unknown", falls back to cdna2) — `rf_exact-arch-bitcode`.

## Proposal (not implemented)

An opt-out such as `OMNIPROBE_ALLOW_UNINSTRUMENTED=1` (warn and continue) could help a user who
wants a Triton workload to run even if instrumentation is broken. Not added: with omniprobe the
user asked for instrumentation, and the CLI's end-of-run summary already covers the opposite
need. Revisit only if someone asks.

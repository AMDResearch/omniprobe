# Dossier — bf_plugin-dhcomms-cuid-duplicate

## Metadata

- Workflow ID: bf_plugin-dhcomms-cuid-duplicate
- Workflow Type: bugfix
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Base Commit: 75ef62b6d87dada3899417d30e18c39af609364d

```write-scope
src/instrumentation/InstrumentationCommon.cpp
tests/test_build_tree_bitcode.sh
```

## Objective

An application of two or more source files builds with `-fgpu-rdc` and any instrumentation plugin.

## Background

Reported by ikimpl: `hipcc -fgpu-rdc -fpass-plugin=... k.hip other.hip` →
`lld: error: duplicate symbol: __hip_cuid_<hash>`; links without the plugin. Reproduced on
5d9266b. Cause: `llvm-dis` of `dh_comms_dev_cdna2_co6.bc` shows
`@__hip_cuid_9d59523df4651ffa = addrspace(1) global i8 0` (in `llvm.compiler.used`);
`loadAndLinkBitcode` links that module into every TU.

## Acceptance Criteria

- **AC-1**: two-file `-fgpu-rdc` build links with each of the three -rocm plugins (suite 13).
  Unfixed: 3/3 fail with the duplicate symbol.
- **AC-2**: the built program runs instrumented (manual: both kernels "Found instrumented
  alternative", MemoryAnalysis accesses for both).
- **AC-3**: full suite 17/17.

## Fix

`__hip_cuid_*` globals of the device module get internal linkage before linking (each TU keeps
a private copy). The submodule is unchanged.

# Dossier — bf_zero-param-kernel-match

## Metadata

- Workflow ID: bf_zero-param-kernel-match
- Workflow Type: bugfix
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Base Commit: f3b9b8f19f798e506f3e9b17bf36a8d4d0a26d32

```write-scope
src/utils.cc
tests/test_intern_linkage.sh
tests/test_kernels/intern_linkage_test.cpp
```

## Objective

A kernel without parameters is instrumented like any other.

## Background

ikimpl 4b: `/tmp/ikimpl/calib/const.hip` (via_constant(), gather_constant()), built with
`-fgpu-rdc` and AddressMessages: "No instrumented alternative found" for both; one unused
pointer parameter hides it. Measured (libstdc++): clone `_Z12via_constantvPv` →
`via_constant(void, void*)`; `getInstrumentedName("via_constant() [clone .kd]")` gave
`__amd_crk_via_constant(, void*) [clone .kd]`.

## Acceptance Criteria

- **AC-1**: suite 16 fixture's `kernel_noargs` and `kernel_static_noargs` run instrumented with
  attributed accesses, both hash flavours. Unfixed: 4 checks fail.
- **AC-2**: ikimpl's repro: both kernels "Found instrumented alternative", accesses reported.
- **AC-3**: full suite 17/17.

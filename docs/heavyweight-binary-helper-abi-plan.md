# Heavyweight Binary Helper ABI Plan

## Purpose

This document turns the recent descriptor audit and trampoline discussion into a
concrete engineering plan for Omniprobe.

The immediate problem is now well defined:

- Omniprobe can already rewrite binaries and run a useful class of helpers.
- Some heavier helpers compile into support code that requests a wider
  kernel-entry ABI than the original kernel descriptor provides.
- Simply patching resource metadata is not sufficient when the helper changes
  ABI semantics.

The goal of this plan is to let Omniprobe support both:

1. a constrained donor-free binary path that remains ABI-stable, and
2. a second binary path that can support heavier helpers by moving ownership of
   the widened entry ABI into compiler-generated code.

## Recommendation Summary

Omniprobe should explicitly support two binary instrumentation tiers.

### Tier A: `binary-safe`

This is the current donor-free clone path with the new fail-closed ABI guard.

Properties:

- original kernel entry ABI is preserved
- only ABI-compatible helpers are accepted
- Omniprobe may patch resource footprint fields
- Omniprobe must not widen entry-state semantics

This tier remains the default because it is simple, testable, and already
useful.

### Tier B: `abi-changing`

This is a new path for heavyweight helpers.

Properties:

- a compiler-generated trampoline owns the widened entry ABI
- the trampoline snapshots and normalizes execution context
- the original kernel body is entered under its original ABI assumptions
- helper code consumes Omniprobe-owned runtime data, not ad hoc live builtins

This tier exists because some helpers cannot be made both expressive and
ABI-compatible with arbitrary precompiled kernels.

## Why a Second Tier Is Required

The descriptor audit showed that helper-induced changes fall into two distinct
classes.

### Class 1: Resource-footprint changes

Examples:

- SGPR count
- VGPR count
- private segment size
- dynamic stack use

These are largely compatible with donor-free regeneration.

### Class 2: Entry-ABI changes

Examples:

- enabling additional workgroup-id SGPRs
- enabling workitem-id VGPR delivery
- enabling dispatch-related SGPRs
- changing any descriptor bit that affects initial kernel execution state

These are not safe to import blindly into a rewritten clone body, because the
original kernel was assembled under a narrower entry contract.

The key design conclusion is:

- Omniprobe can safely own resource growth in a rewritten clone.
- Omniprobe should not pretend to own widened kernel-entry ABI semantics in the
  same rewritten clone body.

If a helper needs a wider ABI, that ABI should be owned by a fresh compiler-
produced entry point.

## Target Architecture

```text
                        +-------------------------+
                        |  original code object   |
                        |  original kernel body   |
                        +------------+------------+
                                     |
                     donor-free      |        abi-changing
                     binary-safe     |        trampoline path
                                     |
                 +-------------------+-------------------+
                 |                                       |
                 v                                       v
      +----------------------+              +------------------------------+
      | clone same entry ABI |              | compiler-generated entry     |
      | patch resources only |              | trampoline owns wider ABI    |
      +----------+-----------+              +---------------+--------------+
                 |                                          |
                 v                                          v
      +----------------------+              +------------------------------+
      | injected tiny stubs  |              | entry snapshot capture       |
      | call ABI-safe helper |              | runtime normalization        |
      +----------+-----------+              | helper dispatch              |
                 |                          +---------------+--------------+
                 v                                          |
      +----------------------+                              v
      | helper/surrogate     |                +-----------------------------+
      | uses omniprobe ctx   |                | transfer into original body |
      +----------------------+                | under original ABI contract |
                                              +-----------------------------+
```

## Design Rules

### Rule 1: Keep the two tiers explicit

Do not hide `abi-changing` behavior behind the current donor-free path.

The user, tests, and runtime should be able to tell whether a rewritten binary
is:

- `binary-safe`, or
- `abi-changing`

This needs to show up in:

- regeneration reports
- cache metadata
- test names
- debug logs

### Rule 2: Keep helper contracts converged

The YAML/helper surface should remain shared across:

- pass-plugin instrumentation
- `binary-safe`
- `abi-changing`

The difference should be backend choice and admissibility, not user-visible
spec fragmentation.

### Rule 3: Treat ABI-changing instrumentation as entry-owned

When a helper requires widened entry semantics, Omniprobe should generate a new
entry kernel rather than trying to mutate the old one into compatibility.

### Rule 4: Make helper-visible execution context explicit

Heavyweight helpers should consume Omniprobe runtime structures populated by the
trampoline:

- entry snapshot
- dispatch-uniform data
- optional dispatch-private data
- optional helper-private scratch/state
- `dh_comms` descriptor and builtin snapshot

The helper should not depend on fallback live-builtin lowering except where
explicitly proven safe.

## Proposed Runtime Model

### Shared runtime root

Continue using the converged hidden/suffix runtime root.

Required fields:

- `dh_comms_descriptor *dh`
- `void *config_blob`
- `void *state_blob`
- `uint64_t dispatch_id`
- `entry_snapshot_v1 *entry_snapshot`
- `dispatch_uniform_v1 *dispatch_uniform`
- `dispatch_private_v1 *dispatch_private`
- `dh_comms::builtin_snapshot_t *dh_builtins`
- `uint32_t abi_version`
- `uint32_t flags`

### New `abi-changing` additions

Add two concepts under Omniprobe ownership:

- `trampoline_mode`
- `body_entry_descriptor`

`trampoline_mode` selects how the generated entry wrapper behaves.

`body_entry_descriptor` describes how to enter the original kernel body safely:

- original kernarg base expectations
- expected enabled workgroup/workitem delivery
- expected scratch/private setup class
- wave32/wave64 body mode
- any arch-specific handoff facts

This descriptor is not the HSA descriptor. It is Omniprobe's handoff model.

## Trampoline Plan

The trampoline path should be implemented as a compiler-generated HIP layer.

### Generated functions

Per instrumented kernel, Omniprobe should generate:

- `__omniprobe_trampoline_<kernel>`
- `__omniprobe_capture_entry_snapshot_<kernel>`
- `__omniprobe_dispatch_<probe_contract>_<kernel>` helpers as needed

### Trampoline responsibilities

1. Receive dispatch under a compiler-owned descriptor.
2. Load the hidden/suffix Omniprobe runtime pointer.
3. Capture entry-only execution context.
4. Materialize helper-visible runtime structures.
5. Optionally run entry instrumentation.
6. Normalize machine state for the original body.
7. Transfer control into the original kernel body.

### Body handoff responsibilities

The handoff code is the core technical challenge.

It must guarantee that the original kernel body starts with the state it
expects, even though the dispatch initially targeted the trampoline instead.

At minimum, the handoff layer needs to account for:

- kernarg base pair
- private scratch base / wave-private offset path
- workgroup-id availability
- workitem-id availability and packing form
- wave size mode
- any mandatory live-ins required by the original body's first block

This should consume the fact inventory described in
`docs/amdgpu-entry-abi-tracking-plan.md`.

## Phased Implementation Plan

### Phase 0: Preserve and tighten `binary-safe`

Status:

- already underway
- fail-closed ABI guard exists

Tasks:

- keep the current ABI guard in `regenerate_code_object.py`
- classify helper contracts as `binary-safe` or `requires-abi-changing`
- make support-wrapper inspection part of every binary regeneration report
- add more fixture cases for helpers that should be rejected

Primary files:

- `tools/codeobj/regenerate_code_object.py`
- `tools/codeobj/generate_binary_probe_thunks.py`
- `tools/codeobj/plan_probe_instrumentation.py`
- `tests/run_binary_probe_support_abi_guard_tests.sh`

Acceptance:

- incompatible helpers fail before runtime
- existing binary-safe suites continue to pass

### Phase 1: Build the `abi-changing` planning layer

Tasks:

- extend probe planning to classify a planned instrumentation bundle as:
  - `binary-safe`
  - `abi-changing`
- report which support-wrapper ABI features force `abi-changing`
- define a regeneration report schema that records:
  - selected mode
  - support-wrapper ABI requirements
  - source-kernel ABI facts
  - reason for fallback or rejection

Primary files:

- `tools/codeobj/plan_probe_instrumentation.py`
- `tools/codeobj/regenerate_code_object.py`
- `tools/codeobj/amdgpu_entry_abi.py`
- `tools/codeobj/analyze_amdgpu_entry_abi.py`

Acceptance:

- Omniprobe can explain why a helper is safe, rejected, or requires a
  trampoline

### Phase 2: Compiler-generated entry trampoline prototype

Tasks:

- generate a minimal HIP entry trampoline for one kernel
- compile it for `gfx1030`
- inject the hidden runtime pointer and entry snapshot plumbing
- verify that the trampoline can call an entry helper and return without
  entering the original body yet

Scope restriction:

- lifecycle-style entry helper only
- no body transfer yet

Primary files:

- new: `tools/codeobj/generate_entry_trampolines.py`
- `tools/codeobj/compile_binary_probe_support.py`
- `inc/omniprobe_probe_abi_v1.h`
- `src/interceptor.cc`

Acceptance:

- dispatch can target the trampoline hsaco symbol
- helper receives runtime context from the trampoline path
- host sees `dh_comms` output from the trampoline entry helper

### Phase 3: Original-body handoff prototype

Tasks:

- define a minimal handoff contract for one validated kernel family
- transfer from trampoline into the original body entry block
- validate that the kernel computes the original result correctly after the
  handoff
- start with one arch and one constrained body pattern

Recommended first target:

- `gfx1030`
- wave32
- source kernels with simple workgroup-id-x only entry contract

Primary files:

- new: `tools/codeobj/generate_body_handoff.py` or equivalent helper module
- `tools/codeobj/amdgpu_entry_abi.py`
- `tools/codeobj/inject_probe_calls.py`
- `tools/codeobj/regenerate_code_object.py`

Acceptance:

- trampoline dispatch enters the original body and the kernel still produces the
  correct output
- no helper-induced ABI faults occur on the validated target set

### Phase 4: Mid-kernel heavyweight helper support through the trampoline model

Tasks:

- make the trampoline-owned runtime structures available to mid-kernel helper
  dispatchers
- route heavier helper contracts through trampoline-owned runtime state instead
  of live builtins
- validate `dh_comms`-heavy helpers that currently fail under `binary-safe`

Primary files:

- `tools/codeobj/generate_binary_probe_thunks.py`
- `tools/codeobj/generate_entry_trampolines.py`
- `external/dh_comms` integration points already used by Omniprobe

Acceptance:

- the previously failing mixed-memory helper can run under `abi-changing`
- host-visible `dh_comms` output is observed

### Phase 5: RDNA/CDNA backend expansion

Tasks:

- extend entry ABI fact fixtures for `gfx90a` and `gfx942`
- validate handoff classes per architecture family
- keep the fallback behavior strict when the body pattern is not supported

Primary files:

- `tests/probe_specs/fixtures/amdgpu_entry_abi_*.json`
- `tests/run_amdgpu_entry_abi_tests.sh`
- `tools/codeobj/amdgpu_entry_abi.py`

Acceptance:

- arch support is explicit, tested, and fail-closed

## Concrete Near-Term Deliverables

The next implementation steps should be these, in order.

1. Add a planner/regenerator notion of `instrumentation_mode` with values:
   - `binary-safe`
   - `abi-changing`
2. Add regeneration-report fields describing the exact ABI delta that caused the
   mode choice.
3. Create `generate_entry_trampolines.py` that emits a minimal entry-only
   trampoline for one kernel.
4. Add a dedicated test that dispatches directly into a trampoline-owned entry
   helper and verifies host-visible `dh_comms` output.
5. Only after that, implement original-body handoff.

The important sequencing point is that trampoline dispatch should be validated
independently before body transfer is attempted.

## What Should Stay Out Of Scope For Now

To keep this tractable, the first `abi-changing` landing should not attempt:

- arbitrary multi-kernel cross-calls
- generic reconstruction of every possible source-kernel prologue shape
- whole-program binary relinking beyond what Omniprobe already does
- fully generic CDNA/RDNA parity in the first prototype
- inline user ISA snippets in the trampoline path

## Success Criteria

This plan is successful when Omniprobe can do all of the following:

1. accept a helper under `binary-safe` and regenerate a donor-free carrier
   without widening the source entry ABI
2. reject an incompatible helper under `binary-safe` with a precise diagnostic
3. classify the same helper as `abi-changing`
4. generate a compiler-owned trampoline for that helper
5. dispatch through that trampoline and observe correct helper behavior
6. eventually transfer into the original kernel body while preserving original
   computation on a validated kernel set

## Recommendation On Product Behavior

Omniprobe should expose this honestly to users.

Suggested behavior:

- default to `binary-safe`
- if helper ABI requirements exceed source-kernel ABI, either:
  - fail with a diagnostic, or
  - allow an explicit opt-in to `abi-changing`

That keeps the stable path predictable while still making room for a more
powerful backend.

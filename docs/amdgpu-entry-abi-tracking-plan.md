# AMDGPU Entry ABI Tracking Plan

## Problem

Omniprobe's binary entry instrumentation now works on validated kernels, but
some of the current lowering logic still reflects backend-shaped assumptions
that are not yet tracked systematically:

- a temporary packed workitem carrier currently uses `v31`
- workitem-id reconstruction currently assumes the common 10/10/10 packing
  shape
- private scratch addressing currently assumes the observed `s0:s1 + s15`
  entry pattern
- builtin reconstruction relies on descriptor-derived ordering plus a small
  number of observed prologue conventions

Those choices are no longer one-kernel hacks, but they are still too implicit.
They should be justified by explicit backend observations and validated per
target family.

## Goal

Build a backend-tracking layer for entry ABI facts that:

1. makes AMDGPU entry assumptions explicit
2. validates them against compiler-generated reference kernels
3. localizes arch- and compiler-specific facts in one place
4. lets entry injection consume a structured fact table instead of scattered
   hardcoded choices

The practical initial portability target is:

- RDNA (`gfx1030`)
- CDNA2 (`gfx90a`)
- CDNA3 (`gfx942`)

## Initial ROCm 6.4 Reference Observations

The first reference-kernel campaign was run on `trippy` with ROCm 6.4.1 and a
single kernel that exercised:

- `threadIdx.{x,y,z}`
- `blockIdx.{x,y,z}`
- `gridDim.{x,y,z}`
- private scratch

Observed entry facts from that compile:

| Target | User SGPRs | Workitem IDs | Scratch / private base path | Wave size |
|--------|------------|--------------|------------------------------|-----------|
| `gfx1030` | 8 | direct `v0/v1/v2` | `s_setreg_b32` flat-scratch init plus explicit `s0:s1 += private_offset` | 32 |
| `gfx90a` | 8 | packed `v0` with `v_bfe_u32` / `v_and_b32` unpack | `flat_scratch_lo/hi` alias init plus explicit `s0:s1 += private_offset` | 64 |
| `gfx942` | 2 | packed `v0` with `v_bfe_u32` / `v_and_b32` unpack | `s_mov_b64 s[0:1], src_private_base` | 64 |

Two immediate consequences follow from these observations:

1. The current entry helper path's `v31` temporary is a policy choice, not a
   backend fact, and many real kernels do not allocate enough VGPRs to make
   that policy universally valid.
2. Private-segment setup is already split across at least three prologue
   families, so the injector should consume a named pattern class instead of
   assuming one hardcoded entry sequence.

## Scope

This plan is about entry ABI tracking for binary helper injection. It is not a
general ISA-independent solution and it is not a replacement for the broader
AMDGPU backend split described in
[`docs/amdgpu-backend-architecture-plan.md`](/Users/keithlowery/distest/omniprobe-work/docs/amdgpu-backend-architecture-plan.md).

## Observed Fact Classes

The backend-tracked fact model should cover at least:

### 1. Descriptor-Derived Entry Facts

- `user_sgpr_count`
- enabled system SGPRs:
  - workgroup id x/y/z
  - workgroup info
  - private-segment wave offset
- enabled workitem-id VGPR count
- wave32 / wave64 mode
- allocated SGPR/VGPR counts
- private-segment fixed size

These are already available from code-object descriptors and should be treated
as the first source of truth.

### 2. Observed Prologue Facts

- early flat-scratch initialization pattern
- observed kernarg base pair
- observed private scratch base materialization
- observed use of the private-segment wave offset SGPR
- observed entry builtin reconstruction patterns

These facts come from compiler-generated reference kernels and are used to
confirm or refine descriptor-derived assumptions.

### 3. Observed Builtin Materialization Facts

- how `threadIdx`, `blockIdx`, and `gridDim` are reconstructed
- whether packed workitem state is consumed directly or unpacked immediately
- whether wave32 vs wave64 changes the relevant entry shape

### 4. Observed Device-Call Facts

This already exists in the device-call ABI path and should remain part of the
same backend fact inventory rather than a separate ad hoc subsystem.

## Reference-Kernel Campaign

Introduce a small set of canonical HIP reference kernels per target family.

Recommended initial kernel set:

1. `entry_thread_ids`
   - touches only `threadIdx`
2. `entry_block_ids`
   - touches `blockIdx`
3. `entry_grid_dims`
   - touches `gridDim`
4. `entry_private_scratch`
   - forces private scratch setup
5. `entry_helper_call`
   - calls a small device helper with a lifecycle-like argument pattern
6. `entry_dh_comms`
   - uses the heavier helper/runtime path

The goal is not to test end-user functionality here. The goal is to harvest
backend facts:

- prologue shapes
- register conventions
- builtin transport idioms
- scratch usage patterns

## Artifact Strategy

For each target family, store generated reference artifacts under
`tests/probe_specs/fixtures/` or a neighboring backend-fixture directory:

- lowered machine IR JSON
- inspected descriptor/metadata manifest JSON
- compact extracted ABI-facts JSON

The compact facts file should be the stable fixture consumed by tests.

The larger IR/manifests are supporting evidence and regeneration inputs.

## Implementation Plan

### Phase 1: Add an Entry-ABI Analyzer

Create a dedicated analyzer, parallel to the existing device-call ABI analyzer,
that reports:

- descriptor-derived entry live-ins
- inferred/observed kernarg base
- inferred workitem VGPR count
- observed early prologue scratch setup
- observed use of system SGPRs in the entry window
- whether the sample matches one of the supported backend patterns

This should be analysis-only and produce JSON.

### Phase 2: Add Entry-ABI Fixtures

For `gfx1030`, `gfx90a`, and `gfx942`:

- compile the canonical reference kernels
- inspect the resulting hsaco
- lower/disassemble the entry functions
- generate and check in compact ABI-facts fixtures

### Phase 3: Add Entry-ABI Tests

Add a new test suite that validates:

- descriptor-derived entry live-in ordering
- workitem-id VGPR count
- observed scratch-base pattern class
- observed wave mode
- any arch-specific deviations from the default expectation

This test should fail when a backend/compiler revision changes the observed ABI
shape in a meaningful way.

### Phase 4: Refactor Injector to Consume Fact Tables

Move the current implicit policy into a structured backend fact layer:

- temporary workitem carrier policy
- spill strategy selection
- packed-workitem reconstruction policy
- scratch-address formation policy
- builtin setup/restore policy

The injector should ask for a backend pattern class instead of embedding the
choice directly.

### Phase 5: Split Hard Constraints from Soft Heuristics

Classify each current assumption:

- **hard ABI fact**
  - must match the backend/compiler behavior to remain correct
- **backend policy**
  - Omniprobe may choose among several legal implementations
- **temporary heuristic**
  - acceptable only until replaced by a backend fact or a stronger policy

Current examples:

- `user_sgpr_count` ordering: hard ABI fact
- private-segment tail growth for spills: backend policy
- fixed choice of `v31` as the packed temporary carrier: temporary heuristic

## Immediate Next Steps

1. Add the entry-ABI analyzer and its JSON schema.
2. Build first-generation fixtures for `gfx1030`, `gfx90a`, and `gfx942`.
3. Convert current injector assumptions into named backend facts or named
   temporary heuristics.
4. Replace the current stale entry smoke test with one that proves helper
   execution out-of-band instead of depending on destructive writes into the
   kernel's logical output.

## Success Criteria

This tracking work is successful when:

- entry injection no longer depends on unexplained register choices
- backend/compiler-sensitive assumptions live in one fact inventory
- tests fail explicitly when observed ABI shapes drift
- RDNA and CDNA support is described by validated backend facts rather than
  inference from a few working kernels

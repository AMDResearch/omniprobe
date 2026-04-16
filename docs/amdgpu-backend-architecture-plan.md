# AMDGPU Backend Architecture Sketch and Implementation Plan

## Purpose

This document sketches a more general binary instrumentation architecture for
Omniprobe. The goal is not to make binary rewriting fully ISA-independent.
That is not realistic for a system that must decode, modify, and rebuild
machine code. The goal is instead to make the design:

- common across Omniprobe frontends where possible
- robust across the AMDGPU family rather than hard-wired to one exact GFX ISA
- explicit about which layers are target-neutral and which remain AMDGPU
  backend responsibilities

The intended scope covers RDNA and CDNA family targets first. That is the
practical portability target for Omniprobe's binary instrumentation work.

## Design Goals

1. Preserve one shared user-facing instrumentation model.
2. Isolate AMDGPU-specific decode, ABI, and emission logic behind a target
   backend.
3. Support multiple rewrite strategies rather than forcing every mutation into
   one patch shape.
4. Use LLVM/ROCm tooling as the source of truth for encode/decode where
   possible.
5. Avoid brittle dependence on one compiler revision's incidental formatting or
   one exact disassembly idiom.

## Non-Goals

- A universal backend that can rewrite any ISA without target-specific logic.
- Reconstructing source-level HIP or LLVM IR from arbitrary hsaco files.
- Replacing LLVM MC, AMDGPU assembly, or AMDHSA metadata conventions with a
  custom Omniprobe assembler.

## High-Level Layering

The right split is:

```text
+---------------------------------------------------------------+
| User-facing Omniprobe instrumentation model                   |
| - probe YAML                                                  |
| - helper HIP source                                           |
| - helper ABI                                                  |
| - runtime hidden-context ABI                                  |
+---------------------------------------------------------------+
                             |
                             v
+---------------------------------------------------------------+
| Common binary instrumentation framework                       |
| - code-object discovery                                       |
| - normalized machine-IR schema                                |
| - mutation planner                                            |
| - rewrite strategy selection                                  |
| - validation/audit/reporting                                  |
| - cache preparation and runtime clone plumbing                |
+---------------------------------------------------------------+
                             |
                             v
+---------------------------------------------------------------+
| Target backend: AMDGPU                                        |
| - disassembly lowering                                        |
| - control-flow recovery                                       |
| - branch/PC-relative legality                                 |
| - register/resource hazard analysis                           |
| - AMDHSA metadata and descriptor materialization              |
| - final assembly emission and code-object rebuild             |
+---------------------------------------------------------------+
```

This means most of Omniprobe remains shared, while AMDGPU-specific facts are
kept in one backend instead of leaking through the whole codebase.

## Core Modules

### 1. Probe and Helper Layer

This remains common across source and binary frontends:

- probe spec validation and normalization
- generated surrogate layer
- helper contract ABI
- runtime context ABI
- `dh_comms` integration policy

The current files under `tools/probes/` and `inc/omniprobe_probe_abi_v1.h`
already point in this direction.

### 2. Common Binary Instrumentation Framework

This layer should be target-neutral and own:

- discovery of standalone and bundled code objects
- orchestration of inspection, mutation, rebuild, and validation
- selection of rewrite strategy
- instrumentation bundle preparation
- reporting of what changed and why

Recommended directories:

```text
tools/binary/
  planner/
  strategies/
  validation/
  orchestration/
```

### 3. Normalized Machine IR

This is not LLVM IR. It is a machine-level normalized representation intended
for safe binary rewriting.

Recommended common schema concepts:

- module
- section inventory
- symbol inventory
- function
- basic block
- instruction
- operand
- control-flow edge
- memory-op classification
- callsite classification
- relocation-like symbolic reference
- mutation markers and provenance

AMDGPU lowering would populate this schema from disassembly plus metadata.
Other targets could populate the same schema differently.

### 4. Rewrite Strategy Layer

Different instrumentation sites need different rewrite shapes. Omniprobe should
select among several strategies rather than forcing one policy everywhere.

Recommended strategy families:

- `same_width_patch`
  - replace an instruction with another instruction sequence of equal size
  - good for minimal proof and bounded semantic edits
- `regional_reassembly`
  - reassemble one CFG region while preserving untouched functions
  - useful when layout changes are local but not global
- `full_function_reassembly`
  - treat the whole function as reassembled text when internal control-flow
    layout changes
  - likely the main path for robust binary instrumentation
- `out_of_line_trampoline`
  - keep the original body mostly intact and branch to an out-of-line probe
    sequence
  - useful when direct insertion is awkward or resource pressure is modest
- `clone_and_redirect`
  - build an instrumented clone and dispatch the clone instead of rewriting the
    original kernel in place
  - aligns with Omniprobe's runtime model
- `whole_object_regeneration`
  - rebuild the full code object when ABI or metadata changes make partial
    patching too fragile

### 5. Target Backend: AMDGPU

The AMDGPU backend should own the target-specific parts:

- lowering from `llvm-objdump` output into machine IR
- AMDGPU branch and PC-relative address materialization analysis
- SGPR/VGPR/resource hazard analysis
- descriptor regeneration and preservation policy
- AMDHSA metadata note regeneration
- final assembly emission
- integration with `llvm-mc` and `ld.lld`

Recommended directories:

```text
tools/binary/targets/amdgpu/
  lowering/
  analysis/
  abi/
  emission/
  validation/
```

## Target Backend Interface

The common framework should not need to know AMDGPU details directly. It should
talk to the backend through an explicit interface.

Recommended conceptual interface:

```text
TargetBackend
  inspect(input) -> TargetObjectModel
  lower(model) -> MachineIR
  analyze_legality(ir, mutation_plan) -> LegalityReport
  choose_strategy(ir, mutation_plan) -> StrategyRecommendation
  apply_mutation(ir, mutation_plan) -> MutatedIR
  materialize_metadata(model, mutated_ir, abi_plan) -> MetadataPlan
  rebuild(mutated_ir, metadata_plan, rebuild_mode) -> OutputObject
  validate(original, rebuilt, mutation_plan) -> ValidationReport
```

This does not need to be implemented as one Python class. The important point
is ownership and separation of concerns.

## Data Flow

The desired end-to-end binary path looks like this:

```text
input hsaco / bundled code object
        |
        v
  inspect + normalize
        |
        v
   machine-IR lowering
        |
        v
  probe selection + mutation plan
        |
        v
 strategy selection
        |
        +--> same-width patch
        +--> trampoline
        +--> full-function reassembly
        +--> whole-object regeneration
        |
        v
 target-specific rebuild
        |
        v
 metadata / descriptor materialization
        |
        v
 structural + launch validation
        |
        v
 cache artifact for Omniprobe runtime clone dispatch
```

## Why This Generalizes Across RDNA and CDNA

This architecture generalizes across RDNA and CDNA because:

- the user-facing layer is target-neutral
- the mutation planner is target-neutral
- the rewrite strategy vocabulary is target-neutral
- the AMDGPU backend can be driven by feature tables rather than one fixed
  ISA assumption
- LLVM MC remains the encoder/decoder source of truth

The backend still needs per-arch knowledge, but that knowledge is localized.

Examples of per-arch backend facts:

- wave32 versus wave64 defaults and legality
- descriptor field availability and meaning
- instruction encodings and operand constraints
- branch range limits and relaxation behavior
- hidden/system SGPR conventions

Those should be represented as backend feature queries, not scattered ad hoc
assumptions.

## Practical Rewrite Policy

The recommended policy bias is conservative:

1. If an instrumentation request can be satisfied by a same-width edit without
   changing CFG layout, allow exact-byte preservation around it.
2. If an edit changes block or function layout, stop preserving raw branch
   encodings in the affected function and switch to function-level textual
   reassembly.
3. If instrumentation changes ABI or clone inventory, allow whole-object
   regeneration and authoritative metadata/descriptor materialization.
4. Preserve untouched functions and untouched non-text sections whenever
   possible.

This keeps the system robust without giving up the efficiency of exact rebuilds
for simple cases.

## Recommended Repository Shape

This is a suggested converged layout rather than a required immediate move:

```text
tools/
  probes/
  binary/
    orchestration/
    planner/
    strategies/
    validation/
    machine_ir/
    targets/
      amdgpu/
        lowering/
        analysis/
        abi/
        emission/
        validation/
```

Existing `tools/codeobj/` content can migrate incrementally into this shape.
The important part is to avoid hard-coding AMDGPU assumptions into the common
planner or probe layers.

## Implementation Plan

### Phase 1. Stabilize the Current AMDGPU Regeneration Backend

Goal:
- make the current donor-free rebuild path explicit as the first AMDGPU backend

Tasks:
- keep `tools/codeobj/` as the working location
- document the current machine-IR contract
- make rebuild reports explicit about whether they used:
  - exact-byte preservation
  - textual instruction reassembly
  - descriptor-byte preservation
  - descriptor regeneration
- add regression coverage for helper-light and helper-heavy objects

Exit criteria:
- current no-op and bounded semantic edit flows are well documented and tested

### Phase 2. Define a Common Machine-IR Schema

Goal:
- separate "normalized machine IR" from "AMDGPU lowering implementation"

Tasks:
- freeze a schema for:
  - functions
  - blocks
  - instructions
  - operands
  - symbolic references
  - mutation markers
- make current AMDGPU lowering populate that schema explicitly
- stop treating objdump text as the de facto internal interface

Exit criteria:
- backend analyses and rewriters consume the schema, not raw objdump text

### Phase 3. Introduce Explicit Rewrite Strategies

Goal:
- stop conflating all binary edits with one rebuild path

Tasks:
- define strategy-selection rules
- implement at least:
  - same-width patch
  - full-function reassembly
  - whole-object regeneration
- emit strategy choice in all reports

Exit criteria:
- Omniprobe can explain why a mutation used one strategy rather than another

### Phase 4. Function-Level Reassembly for Layout-Changing Edits

Goal:
- support general intra-function instrumentation without depending on raw
  preserved branch encodings

Tasks:
- make layout-changing edits invalidate raw encoding preservation for the
  affected function
- rebuild the affected function from textual AMDGPU assembly
- preserve untouched functions byte-exact where legal
- extend symbolic reference handling beyond today's limited PC-relative cases

Exit criteria:
- inserting helper call sequences into real kernels no longer depends on
  donor-slot hacks or one-width substitutions

### Phase 5. Backend Feature Tables for AMDGPU Family Variation

Goal:
- remove implicit single-arch assumptions from the AMDGPU backend

Tasks:
- introduce backend feature queries for:
  - wave mode
  - descriptor capabilities
  - branch/legalization constraints
  - hidden/system SGPR conventions
- validate on at least:
  - one RDNA target
  - one CDNA target

Exit criteria:
- backend logic is feature-driven instead of gfx90a/gfx942/gfx1030 special
  casing scattered through scripts

### Phase 6. Converge Pass-Plugin and Binary Frontends on One Mutation Planner

Goal:
- make source and binary paths differ mainly in where they obtain the editable
  program representation

Tasks:
- map probe spec selectors into a common mutation plan format
- make binary and source frontends both consume:
  - probe spec
  - helper contract metadata
  - clone ABI materialization rules
- leave target-specific code emission in their respective backends

Exit criteria:
- user-facing instrumentation intent is frontend-agnostic

### Phase 7. Promote AMDGPU Backend Structure in the Repository

Goal:
- reflect the architectural split in the tree

Tasks:
- migrate from `tools/codeobj/` toward the backend-oriented layout
- keep compatibility wrappers or aliases while migration is in progress
- avoid breaking existing tests/scripts during the move

Exit criteria:
- the code layout makes backend ownership obvious

## Validation Plan

Every phase should be validated at four levels:

1. Structural fidelity
   - section inventory
   - symbol visibility/binding
   - metadata note coherence
   - descriptor coherence

2. Launch fidelity
   - direct module load / launch
   - HSA launch where needed

3. Runtime instrumentation fidelity
   - helper selection
   - kernarg rewrite
   - `dh_comms` traffic

4. Breadth
   - simple helper-light kernels
   - helper-heavy runtime objects
   - single-kernel external hsacos
   - multi-kernel rocPRIM breadth cases

## Immediate Next Steps

1. Treat the current `tools/codeobj/` pipeline as the initial AMDGPU backend
   and document its contracts more explicitly.
2. Define and freeze the common machine-IR schema in a dedicated design note or
   schema module.
3. Add explicit rewrite-strategy reporting to the current regeneration path.
4. Implement function-level reassembly as the default response to layout-
   changing mutations inside a kernel body.
5. Start moving ad hoc AMDGPU-specific logic behind a target-backend boundary.

## Summary

The right goal is not ISA independence in the abstract. The right goal is a
common Omniprobe binary instrumentation framework with a well-isolated AMDGPU
backend.

That architecture is general enough to span RDNA and CDNA, stable enough to
avoid tight coupling to one exact compiler revision, and conservative enough to
support real kernel instrumentation without pretending that arbitrary machine
code rewriting can be target-agnostic.

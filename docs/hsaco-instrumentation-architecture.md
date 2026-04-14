# HSACO Instrumentation Architecture

This document defines the implementation plan for adding first-class binary-only
HIP kernel instrumentation to Omniprobe while preserving compile-time
instrumentation for source builds.

The target branch for this work is `feature/hsaco-instrumentation-core`.

## Goals

Omniprobe must support two equal instrumentation frontends:

1. LLVM/source instrumentation for HIP applications that can be rebuilt.
2. Code-object instrumentation for `.hsaco` files or bundled GPU code objects
   where no source or build system is available.

Both frontends must converge on the same runtime model:

- instrumented kernel clones discovered by Omniprobe at runtime
- `dh_comms` used for device-to-host streaming
- one shared probe specification format
- one shared helper-function ABI
- one shared hidden-argument ABI for passing Omniprobe instrumentation context

## Core ABI Decision

The long-term ABI for instrumented kernels is a custom hidden argument carried in
kernarg metadata, not an added explicit `void *` parameter and not a suffix load
based on dispatch packet state.

### Why not the current explicit-arg model?

The existing LLVM pass path clones kernels and appends an explicit `void *`
parameter. Omniprobe then rewrites kernargs by inserting that pointer between
explicit and hidden arguments.

That works for compile-time instrumentation because the compiler recompiles the
instrumented clone and can update hidden-argument accesses.

It is not a safe common ABI for binary-only instrumentation because compiled
kernels may already contain fixed assumptions about hidden-argument layout.

### Why not a suffix ABI?

A suffix ABI would preserve the original kernarg blob and append the
instrumentation pointer after it. That approach depends on a reliable way for the
kernel to discover the final kernarg length at runtime. The AMDGPU launch ABI
provides a kernarg pointer, but not a generally available kernarg length value
as an initialized SGPR. The code object contains `KERNARG_SIZE` metadata, but
that is descriptor state, not a guaranteed runtime query mechanism for injected
code.

### Why hidden arguments?

Omniprobe already parses hidden arguments from AMDGPU metadata today.
`KernelArgHelper::computeKernargData()` classifies `.args` records whose
`.value_kind` begins with `hidden_`, and the runtime already models explicit and
hidden regions separately when repacking kernargs.

That existing scaffolding makes a hidden-argument convergence more realistic than
introducing a second unrelated ABI.

## End State

The end state is:

- compile-time frontend: selects instrumentation sites and helper calls during
  compilation, but defers final hidden-argument ABI materialization to a
  code-object stage
- code-object frontend: operates on extracted AMDGPU code objects and performs
  clone creation, helper linkage, metadata updates, and hidden-argument ABI
  materialization directly
- runtime: discovers instrumented clones, repacks kernargs including the
  Omniprobe hidden argument, and swaps dispatches to the clone through the
  existing interceptor path

## Shared Components

### Probe specification

Introduce a probe spec file consumed by both frontends. The spec should define:

- selector
- optional predicate
- helper function to invoke
- capture list

Recommended first selectors:

- kernel name
- function name
- source file / line range when debug info exists
- basic block entry / exit
- callsite before / after
- load / store
- address-space / memory-op class
- ISA mnemonic or opcode class for code-object instrumentation

### Helper ABI

Instrumentation bodies should be expressed as HIP device helper functions.
Injected code should do the minimum amount of work needed to gather values and
call a helper.

The helper receives a probe context structure that includes at least:

- pointer to `dh_comms_descriptor`
- probe id
- capture list pointer / count
- execution builtins that the injector chooses to populate

The helper ABI must not depend on an added explicit kernel parameter.

### Hidden Omniprobe context

Instrumented clones gain one Omniprobe-owned hidden argument, tentatively named
`hidden_omniprobe_ctx`, whose payload points to device-visible instrumentation
state.

The first version of that state should include:

- `dh_comms_descriptor *`
- optional probe table pointer or probe id base
- optional user configuration blob pointer

## Frontend 1: LLVM / Compile-Time Instrumentation

The compile-time frontend remains useful for source builds, but it should stop
being responsible for the final ABI shape.

Its responsibilities become:

- parse the probe spec
- link helper bitcode
- match selectors in LLVM IR
- insert helper-call intent and capture marshaling
- mark kernels/clones for later hidden-argument ABI finalization

The existing fixed-function passes should be refactored into a generic probe
engine. Current hard-coded passes become examples or compatibility wrappers.

## Frontend 2: Code-Object / HSACO Instrumentation

This frontend is required for binary-only `.hsaco` instrumentation and for final
ABI materialization of compile-time-instrumented kernels.

It must be able to:

- extract GPU code objects from bundles when needed
- inspect code object metadata
- clone kernels inside a whole code object
- preserve helper functions and device globals
- link instrumentation helper code
- add `hidden_omniprobe_ctx` to clone metadata / hidden-arg layout
- rewrite injected code to use the hidden-argument location
- rebuild the full code object and rebundle it if needed

This work should migrate and adapt the proven pipeline from the `distest`
workspace into Omniprobe.

## Runtime Integration

Runtime integration should remain recognizably Omniprobe:

- instrumented clones continue to use the `__amd_crk_` naming convention unless
  a stronger alternative emerges
- Omniprobe continues to discover instrumented alternatives via the kernel cache
- the interceptor continues to rewrite dispatches to the clone
- `dh_comms` continues to be the data transport path

The runtime changes are specifically about kernarg metadata and hidden-argument
repacking, not about introducing a separate execution model.

## Implementation Workstreams

### 1. Define the hidden-argument ABI

Deliverables:

- device/host ABI header for probe context
- documentation for `hidden_omniprobe_ctx`
- rules for clone metadata mutation and runtime population

### 2. Generalize kernarg descriptor handling

Extend Omniprobe metadata parsing so it can describe hidden-argument layout in a
way that supports adding a new hidden entry to an instrumented clone.

Required code areas:

- `src/utils.cc`
- `inc/utils.h`
- `src/interceptor.cc`

### 3. Rewrite kernarg repacking around hidden fields

Replace the current “insert explicit `void *` before hidden args” logic with a
model that:

- copies original explicit args unchanged
- copies original hidden args unchanged
- writes `hidden_omniprobe_ctx` into the hidden region for the instrumented
  clone according to metadata-derived offsets

### 4. Introduce a generic probe engine

Refactor current instrumentation plugins into a shared selector/action
framework.

### 5. Migrate code-object tooling from `distest`

Import the extraction, inspection, IR, assembly-emission, and rebuild pipeline
into Omniprobe under a new `tools/codeobj/` area.

### 6. Add code-object ABI finalization

Implement clone metadata mutation, hidden-argument finalization, helper linkage,
and whole-object rebuild in the code-object backend.

### 7. Add binary-only instrumentation flow

Support instrumentation from:

- standalone `.hsaco`
- bundled GPU objects in executables or shared libraries
- multi-kernel code objects with helper/data dependencies

### 8. Add standalone helper compilation

Allow HIP helper functions to be compiled under Omniprobe control for a target
ISA and linked by either frontend.

### 9. Runtime/cache integration

Ensure offline-generated alternates can be discovered and dispatched by the
existing interceptor and kernel cache.

## Test Plan

The branch is not complete without validation for both instrumentation paths.

Validation tiers:

1. hidden-argument metadata parsing and kernarg repacking
2. no-op whole-object rebuild round-trip
3. binary-only helper-call injection into a simple extracted HIP kernel
4. helper-function + device-global dependency-bearing code object
5. rocPRIM multi-kernel breadth case
6. compile-time source instrumentation finalized through the same hidden-arg ABI

## Definition of Done

The branch is complete when Omniprobe can:

- instrument a rebuildable HIP target
- instrument a binary-only `.hsaco` or bundled GPU code object

and both paths produce instrumented clones that:

- use the same hidden-argument ABI
- use the same helper ABI
- stream through `dh_comms`
- are dispatched through Omniprobe’s normal runtime swap mechanism

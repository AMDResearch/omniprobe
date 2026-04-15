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

## Rebuild Modes and Metadata Ownership

The code-object backend must expose a small number of explicit rebuild modes.
These are compatibility contracts, not convenience flags.

### Mode A: Exact Rebuild

Purpose:

- reproduce an existing code object with no intended semantic change
- validate extraction, IR lowering, assembly emission, and relink fidelity
- provide the safest path for cache preparation and whole-object repackaging

Rules:

- preserve original `.text` leading gaps, inter-function gaps, helper ordering,
  and exported symbol envelope
- preserve original note payloads unless a separate metadata rewrite step is
  explicitly requested
- preserve original raw kernel descriptor bytes
- allow whole-object renaming and cache-local packaging changes only when they
  do not change the loader-visible ABI of the kernel itself

Expected use:

- no-op rebuild validation
- bundled-object extraction and repackaging
- baseline before any binary instrumentation work

### Mode B: ABI-Preserving Edit

Purpose:

- allow narrow instruction edits while keeping the original kernel ABI and
  resource contract

Rules:

- preserve original `.text` layout wherever the edited instruction stream still
  fits the existing function envelope
- preserve original hidden-argument and kernarg contract
- preserve original descriptor bytes only when Omniprobe can justify that the
  edit does not change descriptor-sensitive properties
- if descriptor safety cannot be justified, the build must fail closed or be
  promoted to Mode C

Expected use:

- instruction substitutions that do not widen register footprint
- patching a compare, immediate, branch target, or store operand
- narrow binary probes whose injected code reuses already available resources

### Mode C: ABI-Changing Edit

Purpose:

- support instrumentation or mutation that can legitimately change resource
  counts, kernarg layout, hidden arguments, helper linkage, or other loader-
  visible properties

Rules:

- recompute the descriptor and metadata fields that correspond to the changed
  kernel contract
- allow `.text`, `.rodata`, note, and symbol-table updates as needed
- require a higher-confidence rebuild path than ad hoc patching; this is the
  mode for helper injection, hidden-ABI materialization, and full clone
  generation

Expected use:

- introducing `hidden_omniprobe_ctx`
- changing kernarg size or hidden-argument layout
- injecting helper calls that may alter SGPR/VGPR requirements
- relinking a whole code object with new helpers, globals, or probe tables

## Metadata Ownership Matrix

Omniprobe should decide what may change based on mode, not on per-file
heuristics.

### Preserve in all modes unless the operation explicitly requires change

- original kernel symbol names unless clone generation is being performed
- helper symbol order
- exported undefined weak stubs used by the runtime contract
- non-kernel support sections that are not owned by the instrumentation change

### Mode A ownership

- `.text`: preserve exactly
- kernel descriptors: preserve exactly
- metadata note: preserve exactly
- `.dynsym` / `.symtab`: preserve exactly except for purely local packaging
  adjustments
- support sections: preserve exactly

### Mode B ownership

- `.text`: allow narrow instruction edits inside existing envelopes
- kernel descriptors: preserve only after a descriptor-safety check passes
- metadata note: preserve unless the note redundantly carries a field Omniprobe
  has proven must change
- `.dynsym` / `.symtab`: preserve exported ABI
- support sections: preserve unless the edit directly targets them

### Mode C ownership

- `.text`: may change substantially
- kernel descriptors: regenerate or patch explicitly
- metadata note: regenerate or patch explicitly
- `.dynsym` / `.symtab`: may change, but only through explicit clone/link rules
- support sections: may change, but only through explicit ownership by helper
  linkage or probe state insertion

## Descriptor Policy

Descriptor handling should remain deliberately simple.

- Preserving original descriptor bytes is not a performance optimization. It is
  an exact-compatibility mechanism for Modes A and some Mode B edits.
- Descriptor regeneration is required for Mode C and should be treated as a
  contract change, not as a default convenience behavior.
- Omniprobe should avoid an expanding policy tree of “maybe regenerate field X
  if pattern Y”. When the edit is not obviously ABI-preserving, the operation
  should move to Mode C.

The practical consequence is:

- exact rebuilds preserve descriptors
- narrow edits either prove descriptor safety or fail closed
- instrumentation features that need new resources are modeled as ABI-changing
  rebuilds from the beginning

## Compiler Revision Strategy

The backend must assume that LLVM/ROCm revision differences are real and will
surface in code-object shape.

What is stable enough to treat as contract:

- the loaded-code-object interface seen by the runtime
- code-object versioned metadata/note structure
- kernel descriptor format and loader-visible resource fields
- target-architecture-specific execution and memory semantics

What is not stable enough to treat as contract:

- exact helper emission patterns
- assembler-chosen descriptor synthesis details
- incidental symbol ordering beyond what the loader/export ABI requires
- section padding or string-table layout that happens to be emitted by one
  compiler revision

Required engineering stance:

- keep a corpus of regression objects produced by multiple ROCm/LLVM revisions
- record code-object version, target id, and relevant provenance in Omniprobe
  manifests
- prefer preserving original bytes over regenerating derived structures whenever
  the operation does not require semantic change
- require explicit validation when crossing from preservation into regeneration

## Validation Contract

Each mode needs a distinct validator surface.

### Mode A validation

- byte/accounting diff for descriptor bytes, note payload, section addresses,
  symbol addresses, and helper ordering
- runtime launch test where a harness exists

### Mode B validation

- all Mode A structural checks except for the intentionally edited instructions
- descriptor-safety analysis
- runtime behavior check proving the semantic edit took effect

### Mode C validation

- structural diff against an explicit ownership plan
- metadata/descriptor audit showing which fields changed and why
- runtime execution under Omniprobe with kernarg rewrite and helper use enabled

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

This workstream should explicitly target Mode C rather than trying to stretch
Mode A or Mode B mechanisms into full instrumentation.

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

### 10. Rebuild-mode enforcement

Teach Omniprobe tooling to select and enforce Mode A, B, or C explicitly.

Deliverables:

- mode selection in code-object rebuild tooling
- descriptor-safety gating for Mode B
- explicit descriptor/note regeneration path for Mode C
- validation output that states which mode was used and why

## Test Plan

The branch is not complete without validation for both instrumentation paths.

Validation tiers:

1. hidden-argument metadata parsing and kernarg repacking
2. no-op whole-object rebuild round-trip
3. binary-only helper-call injection into a simple extracted HIP kernel
4. helper-function + device-global dependency-bearing code object
5. rocPRIM multi-kernel breadth case
6. compile-time source instrumentation finalized through the same hidden-arg ABI
7. rebuild-mode validation across multiple ROCm/LLVM-produced code objects

## Definition of Done

The branch is complete when Omniprobe can:

- instrument a rebuildable HIP target
- instrument a binary-only `.hsaco` or bundled GPU code object

and both paths produce instrumented clones that:

- use the same hidden-argument ABI
- use the same helper ABI
- stream through `dh_comms`
- are dispatched through Omniprobe’s normal runtime swap mechanism

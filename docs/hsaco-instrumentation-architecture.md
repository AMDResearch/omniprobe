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

### V1 YAML schema

The first user-facing spec should be YAML and deliberately smaller than the
eventual selector DSL. It should express probe placement, helper source,
message mode, and requested captures, but it should not restate execution
context that HIP device code already knows how to query.

In particular, the YAML should not redundantly model:

- `threadIdx`, `blockIdx`, `blockDim`, or `gridDim`
- lane id or execution mask
- wave id / wave number
- wave/thread headers already emitted by `dh_comms`

Those are already available to helper code through HIP builtins and
`dh_comms` headers, and duplicating them in the schema would create two sources
of truth.

Recommended v1 shape:

```yaml
version: 1

helpers:
  source: probes/memory_latency.hip
  namespace: omniprobe_user

defaults:
  emission: auto
  lane_headers: false
  state: none

probes:
  - id: kernel_timing
    target:
      kernels: ["vector_add"]
    inject:
      when: [kernel_entry, kernel_exit]
      helper: kernel_timing_probe
      contract: kernel_lifecycle_v1
    payload:
      mode: scalar
      message: time_interval
    capture:
      kernel_args: [n]
      builtins: [grid_dim, block_dim]

  - id: global_loads
    target:
      kernels: ["vector_add"]
      match:
        kind: isa_mnemonic
        values: ["global_load", "flat_load"]
    inject:
      when: memory_op
      helper: load_probe
      contract: memory_op_v1
    payload:
      mode: vector
      message: address
    capture:
      instruction: [address, bytes, addr_space, access_kind]
      kernel_args:
        - name: input
          type: u64
```

V1 field semantics:

- `helpers.source`: HIP source fragment or translation unit compiled by
  Omniprobe into helper bitcode/object code for the target ISA
- `helpers.namespace`: optional namespace used to avoid collisions between
  generated Omniprobe wrappers and user helper names
- `defaults.emission`: `auto`, `scalar`, or `vector`
- `defaults.lane_headers`: request lane headers for scalar/vector message
  submission when the helper actually emits through `dh_comms`
- `defaults.state`: `none` in v1; reserved to grow into declared helper state
  once Omniprobe has a runtime-backed storage model
- `inject.when`: instrumentation point kind
- `inject.helper`: user-authored helper function name
- `inject.contract`: the event contract the helper implements
- `payload.mode`: preferred `dh_comms` submission mode; this is a policy
  choice, not a separate kernel ABI
- `payload.message`: built-in message family such as `address` or
  `time_interval`; `custom` remains valid when the helper emits its own payload
- `capture.kernel_args`: explicit kernel arguments to marshal into the helper's
  generated capture struct
- `capture.instruction`: dynamic values available at the probe site, such as a
  memory address or access width

### Note on execution-context builtins

The current direction is that execution-context values that are already
available to device code should not become required fields in the stable helper
ABI.

That includes values such as:

- `threadIdx`
- `blockIdx`
- `blockDim`
- `gridDim`
- lane id
- wave id / wave number
- execution mask
- active lane count

Those values can already be queried directly by helper code, and `dh_comms`
already reads several of them when constructing wave and lane headers. For that
reason, `capture.builtins` should be interpreted as a declaration that helper
logic depends on those values, not as a mandate that Omniprobe always marshal
them into the generated capture struct.

The implementation bias should therefore be:

- explicit marshaling for kernel arguments and probe-site dynamic payloads
- helper-side builtin access for execution context
- optional freezing/marshaling only where a specific frontend or analysis truly
  requires it

The important constraint is that YAML chooses from a small number of stable
contracts. It should not allow arbitrary per-probe ad hoc helper signatures,
because that would make the binary frontend brittle and would prevent the LLVM
and code-object paths from converging.

The repository scaffolding for this v1 surface lives in:

- `tools/probes/validate_probe_spec.py` for schema validation and normalization
- `tools/probes/generate_probe_surrogates.py` for generated surrogate source and
  frontend-consumable manifest emission
- `inc/omniprobe_probe_abi_v1.h` for the shared helper/runtime contract types

### Helper ABI

Instrumentation bodies should be expressed as HIP device helper functions, but
Omniprobe should not inject direct calls to arbitrary user helper signatures.
Instead, v1 should separate the problem into three layers:

1. a stable hidden kernel ABI
2. a generated surrogate/wrapper ABI
3. a small family of typed user-helper contracts

The helper ABI must not depend on an added explicit kernel parameter.

### Hidden context ABI

Every instrumented clone receives the same hidden Omniprobe context argument.
That is the only kernel-level ABI extension both frontends are allowed to rely
on.

Recommended v1 runtime context:

```cpp
namespace omniprobe {

enum class event_kind_v1 : uint16_t {
  kernel_entry,
  kernel_exit,
  memory_load,
  memory_store,
  call_before,
  call_after,
  basic_block
};

enum class emission_mode_v1 : uint8_t {
  auto_mode,
  scalar,
  vector
};

struct runtime_ctx_v1 {
  dh_comms::dh_comms_descriptor *dh;
  const void *config_blob;
  void *state_blob;
  uint64_t dispatch_id;
};

struct site_info_v1 {
  uint32_t probe_id;
  uint16_t event_kind;
  uint8_t emission_mode;
  uint8_t has_lane_headers;
  uint32_t user_type;
  uint32_t user_data;
};

} // namespace omniprobe
```

`runtime_ctx_v1` is shared across all probes. Different instrumentation points
must not invent their own hidden-argument layout.

### Generated surrogate ABI

Omniprobe should compile or synthesize a site-specific device surrogate for
each probe. The injected code calls the surrogate, not the user helper
directly.

That solves two problems:

- the injector only has to materialize values that actually exist at the probe
  site
- the user helper can see a structured contract instead of a long positional
  argument list

The surrogate is responsible for:

- loading `hidden_omniprobe_ctx`
- constructing `site_info_v1`
- gathering any requested kernel arguments into a generated capture struct
- gathering site-local event values such as memory address, byte count, or
  timestamp
- calling the user helper with the appropriate typed contract

### User helper contracts

Different instrumentation points do imply different payload needs, but they do
not justify unrelated top-level runtime ABIs.

The right v1 split is:

- one common runtime context ABI
- one common site metadata ABI
- a small family of event payload contracts

That means kernel-entry and memory-op instrumentation should not be forced into
the same dummy "everything struct", but they also should not create arbitrary
per-probe signatures.

Recommended v1 contract families:

```cpp
namespace omniprobe {

template <typename Captures, typename Event>
struct helper_args_v1 {
  const runtime_ctx_v1 &runtime;
  const site_info_v1 &site;
  const Captures &captures;
  const Event &event;
};

struct kernel_lifecycle_event_v1 {
  uint64_t timestamp;
};

struct memory_op_event_v1 {
  uint64_t address;
  uint32_t bytes;
  uint8_t access_kind;
  uint8_t address_space;
};

struct call_event_v1 {
  uint64_t timestamp;
  uint32_t callee_id;
};

struct basic_block_event_v1 {
  uint64_t timestamp;
  uint32_t block_id;
};

} // namespace omniprobe
```

User helpers then implement one of a small number of typed entry points, for
example:

```cpp
extern "C" __device__ void kernel_timing_probe(
    const omniprobe::helper_args_v1<MyCaptures,
    omniprobe::kernel_lifecycle_event_v1> &args);

extern "C" __device__ void load_probe(
    const omniprobe::helper_args_v1<MyCaptures,
    omniprobe::memory_op_event_v1> &args);
```

### Why this answers the entry/exit vs memory-op question

Kernel entry and exit probes are typically interested in:

- timestamps
- counters
- dispatch-local aggregation
- occasional scalar emission to `dh_comms`

Memory-op probes are typically interested in:

- per-lane memory address
- access width
- address space
- load vs store classification

Those are genuinely different dynamic payloads. They should therefore map to
different event contracts such as `kernel_lifecycle_v1` and `memory_op_v1`.

What should stay common is:

- how the helper finds `dh_comms`
- how the helper finds probe/site metadata
- how selected kernel arguments are marshaled
- how both frontends decide which contract a probe uses

So the answer is:

- yes, different instrumentation points imply different event payload
  contracts
- no, they should not imply unrelated hidden-argument ABIs or arbitrary helper
  calling conventions

### Kernel-argument marshaling

Kernel arguments should be exposed to helper code in structured form, but only
for the subset explicitly requested by the spec.

Omniprobe should generate a `Captures` struct per probe that contains:

- selected kernel arguments
- selected builtins that are not already trivial to access directly
- optional static site constants

This is important for binary-only instrumentation. A code object may not carry
enough source-level type information to reconstruct every kernel argument
elegantly, so v1 should only guarantee structured access to arguments the probe
spec explicitly asks for. Where metadata does not provide a strong type, the
spec may need an explicit type override.

### Scalar vs vector `dh_comms` submission

Scalar versus vector emission is a property of the probe site and helper
behavior, not a separate helper ABI.

`dh_comms` already gives Omniprobe the right primitives:

- `v_submit_address` for per-lane memory-address style events
- `s_submit_wave_header` for scalar wave-level markers
- `s_submit_time_interval` for scalar start/stop timing records
- `s_submit_message` and `v_submit_message` for custom payloads

Recommended v1 defaults:

- `memory_op_v1`: `vector` by default
- `kernel_lifecycle_v1`: `scalar` by default
- `basic_block_v1`: `scalar` by default
- `call_event_v1`: `scalar` by default unless the probe explicitly wants
  per-lane behavior

The helper is still free to aggregate locally and emit later, but the contract
family should express what dynamic data is available at the site.

### Stateful entry/exit helpers

Entry/exit instrumentation often wants correlation rather than immediate
emission, for example:

- store a timestamp on entry
- accumulate a counter during execution
- emit a summary on exit

That requirement does not need a separate helper ABI. It needs optional helper
state reachable from the shared runtime context.

For v1, Omniprobe should standardize the pointer slot (`runtime_ctx_v1::state_blob`)
even if the first implementation only supports stateless helpers or a narrow
runtime-provided state model. That keeps the contract compatible between the
pass path and the binary-only path while leaving room for later per-dispatch or
per-wave state allocation.

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

Before ABI finalization work, Omniprobe should land the user-facing v1 spec
surface:

- YAML parser and validator for the probe spec
- generated helper header for `runtime_ctx_v1`, `site_info_v1`, and the v1
  event contracts
- contract resolution that maps `inject.when` plus `inject.contract` to the
  correct generated surrogate shape

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

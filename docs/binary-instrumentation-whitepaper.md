# Binary-Only HIP Kernel Instrumentation in Omniprobe

## Abstract

Omniprobe began as a compile-time instrumentation system for HIP and Triton
applications. In that original model, the target application was rebuilt with an
LLVM pass plugin that cloned kernels, inserted instrumentation calls, and relied
on Omniprobe's runtime to dispatch the instrumented clone instead of the
original kernel.

That model remains important and continues to be supported. It is the most
direct path when source code and a build system are available.

The binary-only instrumentation work extends Omniprobe beyond that model. Its
goal is to make the same style of in-kernel instrumentation possible when the
only artifact available is a compiled AMDGPU code object such as a standalone
`.hsaco` file or a bundled code object embedded in an executable or shared
library.

This document explains how that binary instrumentation architecture works, why
it is structured the way it is, how it differs from the earlier pass-plugin
approach, and where the two frontends converge into one runtime execution
model.

The intended style here is explanatory rather than tutorial. This document is
meant to function as an architectural white paper for engineers who need to
understand the design constraints, the internal data flow, and the tradeoffs
between source-driven and binary-driven instrumentation.

## Problem Statement

There are two distinct deployment environments that Omniprobe must support:

1. A source-available environment, where the user can rebuild HIP code and add
   an LLVM pass plugin to the normal compilation flow.
2. A binary-only environment, where the user has no source code and no control
   over the original build, but does have access to the resulting GPU code
   object.

The first environment is already well served by the pass-plugin path. The
second is not.

The central technical challenge is that Omniprobe is not an offline static
analysis tool. It does not merely inspect a kernel and report metadata. It
injects live instrumentation into the kernel and then participates in the
runtime dispatch path so the instrumented clone executes in place of the
original.

That means the binary-only path must do more than disassemble machine code. It
must establish a full end-to-end execution path with these properties:

- it must locate or derive an instrumentable representation of the kernel
- it must inject new instrumentation behavior
- it must preserve or deliberately regenerate the metadata required for the
  resulting code object to launch correctly
- it must produce a clone whose name and ABI fit Omniprobe's runtime dispatch
  model
- it must hand Omniprobe enough information to rewrite kernargs correctly at
  launch time
- it must converge on the same helper ABI and `dh_comms` runtime model used by
  the source instrumentation path

## Historical Baseline: The Pass-Plugin Model

Before the binary-only work, Omniprobe's core mental model was:

- compile HIP code with an LLVM pass plugin
- clone the kernel inside the compiler pipeline
- append an instrumentation argument to the clone
- insert calls to device-side `dh_comms` helpers
- leave both the original kernel and the clone in the final code object
- have Omniprobe's interceptor redirect dispatches to the clone and rewrite
  kernargs to provide the `dh_comms` descriptor

That model remains valid. It is still the best path when the application can be
rebuilt.

### Pass-Plugin Flow

```text
+------------------+
| HIP source code  |
+---------+--------+
          |
          v
+---------------------------+
| hipcc / clang front-end   |
| with LLVM pass plugin     |
+-------------+-------------+
              |
              v
+----------------------------------+
| Pass plugin clones kernel        |
| and injects instrumentation      |
+-------------+--------------------+
              |
              v
+----------------------------------+
| Final code object contains:      |
| - original kernel                |
| - instrumented clone             |
+-------------+--------------------+
              |
              v
+----------------------------------+
| Omniprobe runtime interceptor    |
| swaps dispatch to clone          |
| and rewrites kernargs            |
+-------------+--------------------+
              |
              v
+----------------------------------+
| Instrumented kernel emits data   |
| through dh_comms                 |
+----------------------------------+
```

The strength of this approach is that the compiler performs the hard parts:

- register allocation
- instruction scheduling
- metadata regeneration
- kernel-descriptor coherence
- hidden-argument management for the final compiled clone

The weakness is obvious: it requires recompilation. When the code object is the
only artifact available, this model cannot even begin.

## Why Binary Instrumentation Is Different

Binary instrumentation is not simply "the same pass later in the pipeline."

At the LLVM level, the compiler has:

- high-level control flow
- type information
- debug metadata in compiler-native form
- explicit symbol ownership
- internal codegen knowledge needed to keep descriptors and metadata coherent

At the binary level, Omniprobe instead sees:

- finalized AMDGPU machine code
- AMDHSA metadata notes
- symbol tables and section layouts
- kernel descriptors and launch metadata
- relocation and support-section state

This is a different engineering problem. The binary frontend must reconstruct
just enough structure to support safe mutation without assuming it can re-run
the whole original compilation pipeline.

That is why the binary path was intentionally built in layers.

## Binary Instrumentation Architecture

The binary-only path is organized around five stages:

1. code-object discovery
2. structural inspection
3. editable representation and mutation
4. clone/ABI materialization
5. runtime dispatch convergence

### Stage 1: Code-Object Discovery

Omniprobe already needed to discover GPU code in executables and libraries to
support runtime swapping of pass-generated clones. The binary path reuses that
foundation.

There are two common cases:

- standalone code objects such as `.hsaco`
- bundled code objects embedded in host binaries

Discovery produces a concrete code-object file or extracted temporary code
object that can be inspected and, if needed, rewritten.

### Stage 2: Structural Inspection

The inspection layer emits a manifest that describes:

- kernels
- descriptors
- metadata notes
- helper functions
- non-text sections such as `.rodata`, `.data`, and `.bss`
- symbol layout and visibility

This stage is critical because binary instrumentation cannot treat the code
object as "just instructions." Launch behavior depends on metadata that lives
outside `.text`.

### Stage 3: Editable Representation and Mutation

The binary tooling lowers disassembly into an editable instruction-level IR.
That IR is not source-level HIP and it is not LLVM IR. It is a practical
intermediate layer designed around safe patching and round-tripping.

The design intent is:

- unchanged instructions can remain byte-exact where possible
- edited instructions can be reassembled from text
- surrounding metadata can be preserved, selectively regenerated, or rewritten
  according to the mutation contract

This is the point where Omniprobe can answer questions such as:

- can this mutation preserve the original descriptor bytes?
- does the kernel need an ABI-preserving rebuild?
- does this change require a true ABI-changing rewrite?

### Stage 4: Clone and ABI Materialization

This stage is where the binary path becomes an Omniprobe path rather than a
generic AMDGPU rewriting toolkit.

Omniprobe does not merely patch an original kernel in place. Its runtime model
expects to dispatch a clone that is discoverable as an instrumented alternative
to the original. That means the rewritten code object must expose:

- a clone name that the runtime can find
- launch metadata that describes the clone correctly
- an Omniprobe-compatible instrumentation context ABI
- a linkage story for helper code and any required support functions

The branch work to date has established two important submodes:

- ABI-preserving mutation, where instruction edits do not require changing the
  clone's argument contract
- ABI-changing mutation, where Omniprobe introduces additional launch-visible
  state and therefore must update metadata and kernarg handling

### Stage 5: Runtime Dispatch Convergence

The most important design principle is that the binary path does not create a
second runtime.

Instead, both frontends converge on the same runtime behavior:

- Omniprobe discovers an instrumented alternative
- the original kernel launch is intercepted
- a `dh_comms` object is checked out for the dispatch
- kernargs are repacked for the clone ABI
- the clone executes and streams data through `dh_comms`

This convergence is the architectural center of the work.

## End-to-End Binary Flow

```text
+------------------------------+
| Original host binary / hsaco |
+---------------+--------------+
                |
                v
+-------------------------------+
| Extract or identify code      |
| object(s) of interest         |
+---------------+---------------+
                |
                v
+-------------------------------+
| Inspect ELF + AMDHSA metadata |
| and emit manifest             |
+---------------+---------------+
                |
                v
+-------------------------------+
| Lower disassembly to editable |
| instruction IR                |
+---------------+---------------+
                |
                v
+-------------------------------+
| Apply Omniprobe mutation      |
| strategy                      |
| - exact / abi-preserving      |
| - abi-changing                |
+---------------+---------------+
                |
                v
+-------------------------------+
| Rebuild or rewrite code       |
| object with Omniprobe clone   |
+---------------+---------------+
                |
                v
+-------------------------------+
| Omniprobe runtime discovers   |
| clone as alternative kernel   |
+---------------+---------------+
                |
                v
+-------------------------------+
| Interceptor swaps dispatch    |
| and repacks kernargs          |
+---------------+---------------+
                |
                v
+-------------------------------+
| Clone executes with helper    |
| and dh_comms runtime context  |
+-------------------------------+
```

## The Role of Carriers and Surrogates

Binary instrumentation has to answer a practical question that source
instrumentation gets "for free" from the compiler:

Where does the instrumented clone live?

There are two broad answers in the current design vocabulary.

### Compiler-Generated Carriers

A carrier is a real code object that already contains:

- an original kernel
- an instrumented clone
- working runtime linkage for the helper path

These are useful because they let Omniprobe study actual compiler-generated
artifacts and learn what changed between the original kernel and the clone.

That has strong diagnostic value, but it is not enough on its own, because
binary-only instrumentation must work when no such compiler-produced carrier is
available.

### Binary-Level Surrogates

A surrogate is Omniprobe's binary-side mechanism for producing the clone-side
behavior needed by the runtime model even when the original code object had no
instrumented clone.

In practice, the branch work has used "surrogate" in two related senses:

- a rewritten or repurposed kernel slot that becomes the clone from the
  runtime's point of view
- a generated helper-call wrapper that presents a stable frontend ABI to the
  instrumentation pass or binary mutator

The terminology matters because the source path and binary path now share the
generated helper-surrogate layer even though one is compiler-driven and the
other is code-object-driven.

## Shared Probe-Spec and Helper ABI

One of the most important architectural decisions in this branch is that the
frontends should not inject arbitrary user helper signatures directly.

Instead, the system is converging on:

- a user-facing probe specification
- generated surrogate functions with stable signatures
- a small family of typed helper contracts
- one shared runtime context ABI

This removes a major source of brittleness.

Without this layer, the source frontend and binary frontend would each need
their own ad hoc mapping from "probe intent" to "helper call signature." That
would quickly diverge.

With the surrogate layer, both frontends target the same generated entry
points.

### Helper Call Flow

```text
+------------------------------+
| User probe spec + HIP helper |
+---------------+--------------+
                |
                v
+-------------------------------+
| Omniprobe surrogate generator |
| emits stable wrapper(s)       |
+---------------+---------------+
                |
                +--------------------------+
                |                          |
                v                          v
+-------------------------------+   +------------------------------+
| LLVM/source frontend injects  |   | Binary frontend injects or   |
| call to generated surrogate   |   | rewrites call to surrogate   |
+---------------+---------------+   +---------------+--------------+
                |                                   |
                +-------------------+---------------+
                                    |
                                    v
+---------------------------------------------------+
| Generated surrogate builds helper_args and calls   |
| user helper under shared ABI                       |
+-------------------------------+-------------------+
                                |
                                v
+---------------------------------------------------+
| User helper emits through dh_comms using runtime   |
| context, site metadata, and typed event payload    |
+---------------------------------------------------+
```

## Comparison with the Pass-Plugin Approach

The two frontends now solve the same high-level problem in different places.

### Source / Pass-Plugin Path

- mutation point: LLVM IR during compilation
- clone production: compiler-generated
- metadata coherence: compiler-owned
- register/resource recomputation: compiler-owned
- best use case: source available, normal rebuild possible

### Binary / Code-Object Path

- mutation point: finalized code object
- clone production: Omniprobe-generated or Omniprobe-rewritten
- metadata coherence: Omniprobe-owned
- register/resource correctness: inferred, preserved, or selectively regenerated
- best use case: source unavailable, build unavailable, only code object exists

### Practical Contrast

```text
Pass-plugin path:
  source -> compiler IR -> instrumented clone -> runtime swap

Binary path:
  code object -> inspection/rewrite -> instrumented clone -> runtime swap
```

The convergence point is the runtime swap, not the frontend.

That distinction is critical. Omniprobe does not require the frontends to look
the same internally. It requires them to produce clones that the runtime can
launch under one coherent dispatch model.

## Why the Runtime Still Matters

It is tempting to think of binary instrumentation as a purely offline rewrite
problem. In Omniprobe, it is not.

The runtime still owns:

- alternative-kernel discovery
- dispatch interception
- `dh_comms` object provisioning
- kernarg repacking
- hidden-argument propagation
- code-object and symbol discovery for handlers and analysis

That is why the binary work has spent so much time on descriptor interpretation,
kernarg descriptors, hidden-argument layout, and clone naming. Those are the
bridges between offline mutation and live execution.

## Hidden ABI and Kernarg Repacking

The earlier compile-time model appended an explicit `void *` argument to the
clone and then rewrote kernargs accordingly. That was sufficient for the pass
path but too narrow to serve as the long-term binary instrumentation contract.

The broader branch direction is to converge on a hidden-ABI model where
Omniprobe-managed context is represented in launch metadata rather than merely
as an appended explicit source-visible parameter.

That is important because binary-only instrumentation must be able to mutate
code objects that already have their own hidden arguments, their own kernarg
layouts, and their own descriptor assumptions.

Omniprobe's runtime already understands explicit and hidden regions of the
kernarg block, so the binary path is intentionally built around that existing
runtime model rather than inventing a parallel dispatch ABI.

## Execution Context: What Should and Should Not Be Captured

One of the more subtle design questions is whether helper-visible execution
context should be marshaled into explicit capture structs.

The current direction is:

- kernel arguments and site-specific dynamic payloads should be explicit capture
  data
- execution-context values that are already naturally available to device code
  should remain implicit

That means values such as:

- `threadIdx`
- `blockIdx`
- `blockDim`
- `gridDim`
- lane id
- wave id
- execution mask
- active lane count

should generally not be packaged into the stable helper ABI by default.

Those values are already available to helper code through HIP builtins and, in
the case of message submission, are already read by `dh_comms` when it builds
wave and lane headers.

This matters for three reasons:

1. It keeps the helper ABI smaller and more stable.
2. It avoids extra spills and stores at the instrumentation site.
3. It avoids duplicating two sources of truth for the same execution context.

The practical consequence is that any YAML notion of `builtins` should be
treated as a helper-context requirement rather than as a mandate to marshal
those values into the generated capture struct.

The current surrogate generator makes that separation explicit by emitting:

- capture-struct layout metadata for marshaled kernel arguments
- event-field metadata for probe-site dynamic values
- helper-context metadata for builtin execution-context requirements

## Current Branch State

At the time of writing, the branch has established the following:

- code-object extraction, inspection, editable IR lowering, and rebuild support
- no-op and semantic round-trip validation for selected HIP code objects
- hidden-ABI mutation support for clone-side kernarg extension
- shared probe-spec validation and surrogate generation tooling
- shared helper ABI definitions
- pass-path generated-surrogate support for memory operations
- pass-path generated-surrogate support for kernel lifecycle entry/exit
- runtime validation on `trippy` showing that generated surrogate/helper paths
  can execute and emit `dh_comms` traffic under Omniprobe control

That means the core architectural claim is now real:

Omniprobe can support both compile-time and binary-driven instrumentation
frontends while converging on one helper ABI and one runtime dispatch model.

## What the Pass Path Still Does Better

It is also important to be explicit about what remains easier in the pass path.

The pass-plugin approach still has structural advantages:

- it sees source-level types directly
- it can rely on the compiler for resource recomputation
- it can express richer source-correlated instrumentation decisions earlier in
  the pipeline
- it avoids some of the descriptor and metadata fragility of code-object
  surgery

So this work is not about replacing the pass-plugin path. It is about extending
Omniprobe so that binary-only environments are no longer excluded.

## Design Summary

The cleanest summary of the architecture is this:

- the pass-plugin frontend remains the preferred path when rebuilding is
  possible
- the binary frontend exists for code objects that cannot be rebuilt
- both frontends now target one shared surrogate/helper ABI
- both frontends feed one runtime dispatch and `dh_comms` model
- the binary path therefore complements the original Omniprobe design rather
  than competing with it

That is the central architectural result of this branch.

# Entry Snapshot And Trampoline Design

## Context

Omniprobe's current binary-only path proves that we can:

- clone and retarget code objects,
- introduce a converged hidden/suffix runtime context,
- inject entry and mid-kernel call sites, and
- execute compiler-generated helper code from rewritten binaries.

The remaining fragility is concentrated in two areas:

1. the amount of handwritten ISA mutation required to preserve state at a mid-kernel site, and
2. the amount of instrumentation logic that currently depends on understanding AMDGPU entry and helper-call ABI details at the binary rewrite layer.

The design goal of this document is to shift more of that burden onto ROCm's own compiler and backend by:

- capturing stable execution context once at kernel entry,
- minimizing binary-level edits to tiny call/jump stubs,
- centralizing helper marshaling in compiler-generated trampolines, and
- unifying the pass-plugin and binary-only paths around the same helper ABI.

This is not a proposal to branch directly from a kernel entry point into an arbitrary HIP device function while pretending the kernel ABI and device-function ABI are interchangeable. That would simply move the brittleness. The proposal is instead to deliberately define a compiler-owned trampoline layer that we call from the binary rewrite path using a narrow, explicit contract.

## ROCm 7.2 Findings On `trippy`

`trippy` is currently running ROCm `7.2.2` with AMD clang 22.

Targeted probe compilation on `trippy` showed that a noinline HIP device function called from a kernel entry can access and lower the following successfully:

- `blockIdx.{x,y,z}`
- `threadIdx.{x,y,z}`
- `blockDim.{x,y,z}`
- `__lane_id()`
- `__builtin_amdgcn_read_exec()`
- `mbcnt`-style active-lane counting
- `clock64()`
- `__wave_num()`-style derived wave number logic
- `s_getreg_b32 hwreg(HW_REG_HW_ID)`

The important observation is not just that the builtins work, but how they are lowered.

From a compiled probe on gfx1030:

- the noinline helper body reads workgroup ids from `s12:s14`,
- derives thread coordinates from packed lane/thread state in `v31`,
- loads block dimensions through compiler-generated accesses,
- reads `exec` directly,
- uses `s_memtime` for timestamps, and
- uses `s_getreg_b32` for hardware id.

The kernel caller performs compiler-generated setup before the `s_swappc_b64` into the helper. In other words, ROCm 7.2 is already willing to own a meaningful kernel-to-device-function bridge when it sees a normal HIP call edge.

That materially strengthens the case for an architecture that relies more heavily on compiler-generated trampolines and less on handwritten binary instrumentation logic.

## Core Idea

Introduce a two-layer execution model for instrumentation:

1. an entry snapshot layer that captures stable, entry-only state once, and
2. a minimal per-site dispatch layer that captures only dynamic site-local values and forwards them into compiler-generated code.

The binary rewrite layer should no longer try to synthesize rich helper argument state itself. It should only:

- preserve enough machine state to make a call safely,
- materialize a tiny set of scalar arguments, and
- transfer control to a compiler-generated trampoline.

The trampoline is then responsible for:

- reconstructing helper argument structures,
- combining entry snapshot state with site-local dynamic state,
- dispatching to the real helper, and
- interacting with `dh_comms`.

## High-Level Architecture

### 1. Runtime Context

Continue using the converged hidden/suffix runtime context as the primary ABI bridge from the interceptor to instrumented device code.

That context should remain the single root pointer passed to both:

- pass-plugin instrumentation, and
- binary-only instrumentation.

It should carry:

- `dh_comms_descriptor*`
- instrumentation runtime configuration
- per-dispatch state pointers
- pointer to entry snapshot storage

### 2. Entry Snapshot

Define a compiler-visible `entry_snapshot_v1` struct that contains only stable or entry-specific state.

Representative fields:

- workgroup ids
- grid and block dimensions
- packed thread/lane state if needed
- entry `exec`
- entry timestamp
- hardware id / arch-derived tags
- resolved kernel-argument base facts if they are useful at helper level
- any pass-plugin-compatible view of kernel arguments

This snapshot should be written exactly once per relevant thread or lane at kernel entry.

The snapshot is not intended to replace dynamic site-local data. It is intended to eliminate repeated dependency on fragile entry live-in recovery at later insertion points.

### 3. Compiler-Generated Trampolines

Define a generated HIP trampoline layer with explicit, narrow entry points.

Representative entry points:

- `__omniprobe_capture_entry_snapshot_v1(runtime_ctx*, entry_snapshot_v1*)`
- `__omniprobe_dispatch_basic_block_v1(runtime_ctx*, const entry_snapshot_v1*, const basic_block_site_state_v1*)`
- `__omniprobe_dispatch_memory_op_v1(runtime_ctx*, const entry_snapshot_v1*, const memory_site_state_v1*)`
- `__omniprobe_dispatch_call_v1(runtime_ctx*, const entry_snapshot_v1*, const call_site_state_v1*)`

These trampolines should:

- be ordinary HIP functions compiled by ROCm for each target arch,
- own the helper marshaling,
- own any helper ABI quirks,
- own `dh_comms` interaction, and
- call the actual user helper functions.

### 4. Minimal Binary Site Stubs

Binary instrumentation should inject only tiny site stubs.

Entry stub responsibilities:

- locate runtime ctx,
- locate snapshot storage,
- call `__omniprobe_capture_entry_snapshot_v1`,
- return.

Mid-kernel stub responsibilities:

- preserve minimal machine state for a safe call,
- materialize site id,
- materialize timestamp,
- materialize optional payload fields such as:
  - memory address
  - memory access kind
  - basic-block id
  - call target id
- call the appropriate compiler-generated dispatch trampoline,
- restore state,
- continue original control flow.

This leaves the binary-only rewriter with a much smaller and more stable responsibility boundary.

## Why This Should Be Less Brittle

### Entry state is captured before it drifts

If workgroup ids, packed thread state, entry `exec`, or hardware id matter, capturing them at true kernel entry avoids later reconstruction from partially transformed machine state.

### Helper marshaling moves into compiler-owned code

The current approach leaks too much ABI knowledge into binary rewriting:

- helper argument placement,
- builtin access expectations,
- live-in restoration rules,
- and some `dh_comms` interactions.

A trampoline approach lets ROCm lower that logic using the same backend rules it applies to ordinary HIP code.

### Binary edits become simpler

A small call stub is easier to preserve across compiler revisions than a larger handwritten inline instrumentation sequence.

### Pass-plugin and binary-only paths can converge

Both instrumentation paths can target the same generated trampoline/helper contracts instead of each path inventing its own helper invocation model.

## What This Does Not Eliminate

This design does not remove the need for dynamic site-local capture.

Examples:

- a memory-op probe still needs the actual address at the instrumented instruction,
- a basic-block probe still needs the current block id or site id,
- a control-flow probe may still need the current predicate or current `exec`,
- a timing probe still needs a current timestamp at the site.

So the correct design is hybrid:

- immutable or entry-only context from the snapshot,
- dynamic site-local context from the stub.

## Proposed ABI Contracts

### Runtime Root

```c++
struct runtime_ctx_v1 {
  dh_comms_descriptor* dh;
  void* dispatch_private;
  void* entry_snapshot_base;
  void* helper_private;
  uint32_t abi_version;
  uint32_t flags;
};
```

### Entry Snapshot

```c++
struct entry_snapshot_v1 {
  uint32_t workgroup_x;
  uint32_t workgroup_y;
  uint32_t workgroup_z;
  uint32_t block_dim_x;
  uint32_t block_dim_y;
  uint32_t block_dim_z;
  uint64_t entry_exec;
  uint64_t entry_clock;
  uint32_t hw_id;
  uint16_t wave_num;
  uint16_t reserved0;
};
```

### Site State Examples

```c++
struct basic_block_site_state_v1 {
  uint32_t site_id;
  uint32_t block_id;
  uint64_t timestamp;
};

struct memory_site_state_v1 {
  uint32_t site_id;
  uint16_t access_kind;
  uint16_t address_space;
  uint32_t pointee_size;
  uint64_t timestamp;
  uint64_t address;
  uint64_t exec;
};
```

The exact field set should be driven by helper contracts and should remain versioned.

## Integration With Existing Omniprobe Paths

### Pass-Plugin Path

The pass plugin can:

- continue to inject at IR level,
- call the same generated trampoline layer,
- and optionally populate richer site-state structures because it has higher-level source/IR facts.

This avoids bifurcating helper semantics between pass-plugin and binary-only instrumentation.

### Binary-Only Path

The binary-only path should:

- continue to clone or regenerate code objects as it does now,
- continue to use the hidden/suffix runtime context,
- add entry snapshot capture where requested,
- replace richer inline helper setup with minimal site-state stubs,
- and call the same generated trampoline/helper layer as the pass-plugin path.

### Carrier / Surrogate Compatibility

This design is compatible with the existing carrier/surrogate model because:

- the runtime context ABI remains shared,
- the generated trampoline objects can be linked into carrier/surrogate artifacts,
- and the binary-only path still only needs callable device symbols plus a small callsite patch.

## Likely Impact On The Current Mid-Kernel `dh_comms` Problem

This design does not magically make the current gfx1030 mid-kernel `dh_comms` issue disappear.

However, it does improve the debugging and containment boundary:

- entry-specific builtin assumptions can be eliminated from mid-kernel probes,
- helper argument construction can be centralized,
- and any remaining `dh_comms` codegen sensitivity is isolated inside compiler-generated support code rather than spread across binary rewrite logic.

At the time of writing, the observed mid-kernel `dh_comms` failure on gfx1030 is narrower than entry-state corruption. The evidence suggests it is tied to the codegen path used when emitting dynamic `wave_header_t`-style message content. Moving more logic into compiler-owned trampolines is still useful, but `dh_comms` emission may still require a specialized workaround or alternate emission path.

## Implementation Plan

### Phase 0: Record ROCm 7.2 ABI Facts

- Add ROCm 7.2 disassembly fixtures for representative helper calls on gfx1030.
- Extend `amdgpu_entry_abi.py` coverage if needed for any changed live-in conventions.
- Document which entry facts are compiler-owned versus rewrite-owned.

### Phase 1: Add Snapshot And Trampoline Contracts

- Define `entry_snapshot_v1` and site-state structs in a shared header.
- Extend probe-support generation to emit snapshot and dispatch trampolines.
- Keep the helper-facing ABI versioned.

### Phase 2: Entry Snapshot Capture

- Add a binary-only entry insertion mode that calls `__omniprobe_capture_entry_snapshot_v1`.
- Allocate snapshot storage through the existing runtime context/interceptor path.
- Verify on gfx1030 and at least one CDNA target later.

### Phase 3: Minimal Mid-Kernel Site Stubs

- Replace rich helper setup at binary sites with minimal site-state materialization.
- Limit handwritten ISA to:
  - preserving machine state,
  - materializing a compact site-state object or argument bundle,
  - calling the dispatch trampoline.

### Phase 4: Converge Pass-Plugin Path

- Have pass-plugin instrumentation call the same dispatch trampolines.
- Preserve any richer source/IR data as optional site-state extensions rather than a separate ABI.

### Phase 5: `dh_comms` Hardening

- Keep `dh_comms` submission inside compiler-generated support code.
- If ROCm 7.2 still exhibits backend-specific message-emission fragility, add an alternate low-level emission path behind the trampoline layer without changing the binary rewrite ABI.

## Risks And Open Questions

### Device-function call ABI still varies by arch family

RDNA and CDNA may still differ in details. The design is only robust if the trampoline layer is always compiled for the concrete target architecture and the binary rewriter only targets the trampoline symbol contract, not its internal ABI.

### Snapshot storage policy

We need a concrete decision for where per-dispatch or per-wave snapshots live:

- hidden runtime allocation,
- per-dispatch storage in the interceptor,
- or a dedicated device buffer owned by omniprobe.

### Site-state size discipline

If site-state records get too large, the binary-only stub becomes large again. Site-state must remain compact and contract-specific.

### `dh_comms` backend sensitivity

The current gfx1030 failure shows that compiler-generated support code is not automatically immune to backend issues. The trampoline architecture reduces blast radius, but it does not remove the need for targeted backend-aware validation.

## Recommendation

Proceed with the hybrid snapshot/trampoline architecture.

It preserves the most important lesson from the current binary-only work:

- use the binary rewriter to create safe control-transfer points,

while shifting as much semantic complexity as possible into:

- compiler-generated trampolines,
- shared helper ABI contracts,
- and entry-captured snapshot state.

That is the most plausible path to a less brittle omniprobe instrumentation architecture without giving up binary-only support.


## April 17, 2026 Binary-Only Helper Builtin Limitation

Follow-up diagnostics on April 17, 2026 showed that Omniprobe's current binary-only entry bridge does not yet preserve the full helper-visible builtin contract that a normal compiler-generated kernel-to-device call edge provides.

A focused binary-only repro (`tests/test_output/debug_entry_snapshot_gate_intmask`) wrote back a mask of `119`, meaning the helper observed:

- a non-null `entry_snapshot_v1`,
- `snapshot->workgroup_x == 0`,
- `snapshot->thread_x == 0`,
- `snapshot->lane_id == 0`,
- `snapshot->wave_id == 0`, and
- `blockIdx.x == 0`,

but did **not** observe:

- `snapshot->block_dim_x == blockDim.x`, or
- `threadIdx.x < warpSize`.

In other words, the snapshot itself was valid, but helper-local `blockDim.x` and `warpSize` were not reliable in the current binary-only helper path.

This explains why a binary-only entry helper that emitted `dh_comms` traffic unconditionally succeeded, while the same helper wrapped in `entry_snapshot_v1`-plus-builtin gating produced no output: the helper returned early because the builtin-dependent predicates failed.

This does **not** invalidate the earlier ROCm 7.2 standalone findings. Those findings were based on ordinary compiler-generated kernel-to-device calls. The new result is narrower and more actionable: Omniprobe's current rewritten entry-call bridge does not yet reproduce that full builtin contract for out-of-line helpers.

Practical consequence for the current implementation:

- binary-only helper logic should not depend on helper-local `blockDim`, `warpSize`, or similar builtins for correctness,
- binary-only helper contracts should prefer compiler-captured snapshot state and explicitly marshalled site state, and
- the longer-term trampoline ABI should treat helper builtin availability as an implementation detail to be proven, not assumed.

# Dispatch-Uniform Builtin Snapshot Plan

## Problem

Omniprobe's binary-only instrumentation path currently has two different kinds of
execution context:

- shared hidden runtime state carried through `hidden_omniprobe_ctx`
- per-site event state materialized in generated thunks and surrogates

That split is correct, but the current shared runtime state is too small for the
next round of helper and `dh_comms` support.

Today the hidden runtime storage carries:

- `dh`
- `config_blob`
- `state_blob`
- `dispatch_id`
- `entry_snapshot`
- `dispatch_private`
- ABI version / flags

The binary path also exposes `runtime_ctx::dh_builtins`, but there is no
first-class Omniprobe-owned snapshot model behind it. Instead, the current
binary thunks opportunistically call `dh_comms::capture_builtin_snapshot()` and
hand helpers a pointer to a stack-local `dh_comms::builtin_snapshot_t`.

That works only when the invoked device code can still safely use the relevant
launch builtins at the insertion point.

The key limitation is that "builtin" is not one thing:

- some values are dispatch-uniform and should be captured once per dispatch
- some values are workgroup / wave / lane local and must be captured per site
- some values are optional, backend-dependent, or not yet proven stable in the
  donor-free binary path

The current `dh_comms::builtin_snapshot_t` mixes all of those categories in one
struct. That is useful as a compatibility surface for device APIs, but it is not
an ideal storage ABI for Omniprobe.

## Core Observation

A single shared hidden struct can solve the stable, dispatch-uniform part of the
problem.

It cannot solve the non-uniform part.

The design should therefore split execution context into two layers:

1. **Dispatch-uniform snapshot**
   - captured once at `kernel_entry`
   - stored in Omniprobe hidden runtime storage
   - safe to reuse from any later helper call
2. **Per-site execution snapshot**
   - materialized in the generated thunk at the actual insertion point
   - contains workgroup / wave / lane / thread state that is not uniform across
     the dispatch
   - may be partial depending on site kind and rewrite support

This lets Omniprobe stop depending on downstream builtin liveness for values
such as `gridDim`, `blockDim`, and related dispatch metadata, while still
keeping per-thread and per-wave facts explicit.

## Existing Hooks We Should Reuse

The current tree already contains the right seams:

- `runtime_storage_v1` and `runtime_ctx` live in
  `inc/omniprobe_probe_abi_v1.h`
- `runtime_ctx` already has `const dh_comms::builtin_snapshot_t *dh_builtins`
- binary thunks reconstruct `runtime_ctx` in
  `tools/codeobj/generate_binary_probe_thunks.py`
- the interceptor allocates and initializes hidden runtime storage in
  `src/interceptor.cc`
- `dh_comms` device APIs already accept an optional
  `const builtin_snapshot_t *builtins`

This means we do **not** need a second helper ABI and we do **not** need a
special-purpose `dh_comms` side channel. We need a better Omniprobe-owned
snapshot ABI.

## Proposed ABI: `runtime_storage_v2`

Introduce a new ABI version and add a dispatch-uniform snapshot record to the
hidden runtime storage.

### New Types

```c++
inline constexpr uint32_t runtime_ctx_abi_version = 2;

enum dispatch_uniform_valid_bits : uint64_t {
  dispatch_uniform_valid_dispatch_ptr = 1ull << 0,
  dispatch_uniform_valid_kernarg_ptr = 1ull << 1,
  dispatch_uniform_valid_dispatch_id = 1ull << 2,
  dispatch_uniform_valid_grid_dim = 1ull << 3,
  dispatch_uniform_valid_block_dim = 1ull << 4,
  dispatch_uniform_valid_hidden_block_count = 1ull << 5,
  dispatch_uniform_valid_hidden_group_size = 1ull << 6,
};

struct dispatch_uniform_snapshot_v1 {
  uint64_t valid_mask = 0;
  uint64_t dispatch_ptr = 0;
  uint64_t kernarg_segment_ptr = 0;
  uint64_t dispatch_id = 0;
  uint32_t grid_dim_x = 0;
  uint32_t grid_dim_y = 0;
  uint32_t grid_dim_z = 0;
  uint32_t block_dim_x = 0;
  uint32_t block_dim_y = 0;
  uint32_t block_dim_z = 0;
  uint32_t hidden_block_count_x = 0;
  uint32_t hidden_block_count_y = 0;
  uint32_t hidden_block_count_z = 0;
  uint32_t hidden_group_size_x = 0;
  uint32_t hidden_group_size_y = 0;
  uint32_t hidden_group_size_z = 0;
};

struct runtime_storage_v2 {
  dh_comms::dh_comms_descriptor *dh = nullptr;
  const void *config_blob = nullptr;
  void *state_blob = nullptr;
  uint64_t dispatch_id = 0;
  entry_snapshot_v1 entry_snapshot{};
  dispatch_uniform_snapshot_v1 dispatch_uniform{};
  const void *dispatch_private = nullptr;
  uint32_t abi_version = runtime_ctx_abi_version;
  uint32_t flags = 0;
};

struct runtime_ctx {
  dh_comms::dh_comms_descriptor *dh = nullptr;
  const void *config_blob = nullptr;
  void *state_blob = nullptr;
  uint64_t dispatch_id = 0;
  const void *raw_hidden_ctx = nullptr;
  const entry_snapshot_v1 *entry_snapshot = nullptr;
  const dispatch_uniform_snapshot_v1 *dispatch_uniform = nullptr;
  const dh_comms::builtin_snapshot_t *dh_builtins = nullptr;
  const void *dispatch_private = nullptr;
  uint32_t abi_version = runtime_ctx_abi_version;
  uint32_t flags = 0;
};
```

### Why a Separate `dispatch_uniform_snapshot_v1`

Do not store `dh_comms::builtin_snapshot_t` directly in hidden runtime storage.

That struct intentionally mixes:

- dispatch-uniform state: `grid_dim_*`, `block_dim_*`
- workgroup-local state: `block_idx_*`
- lane / wave / thread state: `thread_idx_*`, `lane_id`, `wave_num`, `exec`
- hardware residency state: `hw_id`, `xcc_id`, `se_id`, `cu_id`, `arch`

A single shared hidden object cannot truthfully represent all of those values
for every thread in the dispatch. Storing that type as the shared ABI would blur
which fields are safe to reuse and which are site-local.

`dispatch_uniform_snapshot_v1` should contain only fields that are valid for the
entire dispatch.

## Source-of-Truth Table

The new ABI should define where each class of value comes from.

### Shared / Dispatch-Uniform

Capture once at `kernel_entry` and store in `runtime_storage_v2.dispatch_uniform`:

- `dispatch_id`
  - source: existing host-populated hidden runtime storage
- `dispatch_ptr`
  - source: device builtin / intrinsic at kernel entry
- `kernarg_segment_ptr`
  - source: device builtin / intrinsic at kernel entry
- `grid_dim_{x,y,z}`
  - preferred source: dispatch packet / implicitarg-derived load at entry
  - acceptable fallback: direct builtin at entry while validating toolchain
- `block_dim_{x,y,z}`
  - preferred source: dispatch packet / implicitarg-derived load at entry
  - acceptable fallback: direct builtin at entry while validating toolchain
- `hidden_block_count_{x,y,z}`
  - source: implicitarg region if present and proven stable
- `hidden_group_size_{x,y,z}`
  - source: implicitarg region if present and proven stable

### Per-Site / Non-Uniform

Materialize in the thunk at the insertion site and never store once-per-dispatch:

- `block_idx_{x,y,z}`
- `thread_idx_{x,y,z}`
- `lane_id`
- `wave_num` / `wave_id`
- `wavefront_size`
- `exec`
- `hw_id`, `xcc_id`, `se_id`, `cu_id`, `arch`
- event-specific values such as memory address, callee id, block id, timestamp

### Not Yet ABI-Stable

Do not make these part of the first shared snapshot ABI until we prove the read
path and semantics across target families / compiler revisions:

- raw `queue_ptr`
- multi-grid sync arguments
- private-segment and group-segment bookkeeping that is not already required by
  helper contracts

## Helper Contract Rules

The helper contract should become explicit about which class of state a helper
may assume.

### Rule 1: `runtime->dispatch_uniform` is the authoritative source for
### dispatch-uniform context

Helpers that need:

- `gridDim`
- `blockDim`
- dispatch id
- dispatch-derived sizes

should read from `args.runtime->dispatch_uniform`, not from ad hoc builtins.

### Rule 2: `runtime->dh_builtins` is a compatibility view, not the storage ABI

`runtime->dh_builtins` should point to a thunk-local, per-call
`dh_comms::builtin_snapshot_t` assembled from:

- `runtime->dispatch_uniform` for uniform fields
- site-local event capture for non-uniform fields
- direct builtins only where the insertion-point contract says they are valid

This keeps Omniprobe compatible with the existing `dh_comms` device API without
making `builtin_snapshot_t` the permanent storage contract.

### Rule 3: binary-only support is site-specific

Binary-only helpers should not assume that every insertion point can provide a
full builtin view.

The supported matrix should be:

- `kernel_entry`
  - can populate `dispatch_uniform`
  - can build a complete `dh_builtins` snapshot
- `basic_block` / `memory_op` / `call_*`
  - may build a useful `dh_builtins` snapshot from insertion-site state plus
    `dispatch_uniform`
  - support level should be validated per site kind
- donor-free `kernel_exit`
  - should remain conservative
  - continue to support captures-only helpers unless and until event / builtin
    reconstruction is explicitly validated

## `dh_comms` Integration

The goal is not to rewrite `dh_comms`. The goal is to feed it a better builtin
source.

### Immediate Reuse Path

For any thunk that wants to call `dh_comms` helpers:

1. read `runtime->dispatch_uniform`
2. allocate a local `dh_comms::builtin_snapshot_t builtins{}`
3. fill uniform fields from `dispatch_uniform`
4. fill non-uniform fields from the insertion site if available
5. set `runtime.dh_builtins = &builtins`
6. pass `runtime.dh_builtins` through to `dh_comms` APIs

That gives `dh_comms`:

- stable `grid_dim_*`
- stable `block_dim_*`
- stable `dispatch_id` if Omniprobe wants to mirror it into `user_data`
- opportunistic `block_idx_*`, `thread_idx_*`, `lane_id`, `wave_num`, `exec`
  when the site contract provides them

### Why This Helps

Today a binary helper may fail simply because some downstream code wants
`gridDim.x` or `blockDim.x` and reconstructs them through the normal HIP builtin
path. With the new design, those fields come from a once-per-dispatch snapshot
instead of depending on whether they remain cheaply or safely queryable after
rewrite.

## Binary and Pass-Plugin Convergence

This design should be used by both instrumentation frontends.

### Binary-only path

- `kernel_entry` thunk captures `dispatch_uniform`
- later thunks reconstruct `runtime_ctx` with `dispatch_uniform`
- helper and `dh_comms` calls consume the same runtime interface

### Pass-plugin path

- pass instrumentation should also target the same `runtime_ctx` shape
- if the pass path can cheaply materialize a full builtin view at compile time,
  it may continue to do so
- helper code should still prefer `runtime->dispatch_uniform` for uniform values
  so that helper source behaves consistently in both paths

This avoids creating a pass-only helper vocabulary and a binary-only helper
vocabulary.

## YAML / Probe-Spec Implications

No new YAML surface is required for the first step.

The probe spec should continue to describe:

- placement
- helper function
- payload mode
- captures

The new snapshot ABI is a runtime contract, not a probe-spec feature.

Longer term, if we want to reject helpers that demand unavailable non-uniform
context for a given binary insertion point, that should be modeled through
helper-context metadata, not by adding raw builtin names to YAML.

## Implementation Plan

### Phase 1: Define the ABI in headers

Files:

- `inc/omniprobe_probe_abi_v1.h`

Changes:

- bump ABI version to 2
- add `dispatch_uniform_snapshot_v1`
- add `runtime_ctx::dispatch_uniform`
- keep `runtime_ctx::dh_builtins` as-is
- add comments documenting the shared-vs-local split

### Phase 2: Allocate and initialize `runtime_storage_v2`

Files:

- `src/interceptor.cc`

Changes:

- switch allocation size and alignment to `runtime_storage_v2`
- continue host-initializing host-known fields (`dh`, blobs, `dispatch_id`,
  flags)
- zero-initialize `dispatch_uniform`

### Phase 3: Capture `dispatch_uniform` at `kernel_entry`

Files:

- `tools/codeobj/generate_binary_probe_thunks.py`
- pass-plugin instrumentation path if needed

Changes:

- on `kernel_entry`, gate one origin lane / thread per dispatch
- load dispatch-uniform values once
- store them into `runtime_storage_v2.dispatch_uniform`
- set validity bits only for values actually captured

### Phase 4: Reconstruct a thunk-local `dh_builtins`

Files:

- `tools/codeobj/generate_binary_probe_thunks.py`
- generated surrogate / thunk helper glue as needed

Changes:

- replace unconditional `capture_builtin_snapshot()` with a contract-driven
  builder
- fill uniform fields from `runtime->dispatch_uniform`
- fill non-uniform fields from site event capture or safe insertion-point reads
- set `runtime.dh_builtins` to the local builder result

### Phase 5: Teach helpers / examples to prefer `dispatch_uniform`

Files:

- helper examples under `tests/`
- documentation

Changes:

- update examples that only need `gridDim` / `blockDim` to read from
  `runtime->dispatch_uniform`
- reserve raw builtin use for genuinely site-local state

### Phase 6: Add validation tests

Required tests:

- ABI header / manifest tests for `runtime_ctx` version 2
- binary entry thunk test proving `dispatch_uniform` capture code is emitted
- runtime test proving a binary helper can consume stable `grid_dim` /
  `block_dim` after entry without direct builtin reads
- `dh_comms` runtime test proving the local `dh_builtins` builder path works
  using `dispatch_uniform`-seeded fields
- negative tests for unsupported non-uniform builtin needs at unsupported sites

## Explicit Non-Goals

This proposal does **not** claim that a shared runtime snapshot can replace all
builtins.

It does not solve, by itself:

- arbitrary thread-local builtin recovery at donor-free `kernel_exit`
- backend-independent reconstruction of every lane / wave field
- generic post-codegen recovery of values the original kernel never needed

Those remain insertion-point-specific problems.

## Recommendation

Adopt this split:

- **shared hidden storage** for dispatch-uniform context
- **per-site event materialization** for non-uniform context
- **thunk-local `dh_builtins` assembly** as the compatibility layer for
  `dh_comms`

That gives Omniprobe a deterministic place to cache the values that are truly
uniform, reduces dependence on downstream builtin liveness, and keeps the
existing helper / `dh_comms` surface converged between the pass-plugin and
binary-only paths.

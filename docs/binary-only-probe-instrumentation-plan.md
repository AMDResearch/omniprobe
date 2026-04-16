# Binary-Only YAML/Helper Instrumentation Plan

## Goal

Add first-class support for Omniprobe's v1 probe-spec workflow to the
binary-only code-object rewrite path so a user can take:

- a standalone `.hsaco` or bundled AMDGPU code object,
- a v1 probe YAML file,
- a HIP helper source file,

and produce a rewritten code object that contains:

- the original kernel bodies,
- Omniprobe clone kernels,
- injected probe-site calls into generated surrogates,
- linked helper device code,
- Omniprobe's hidden `hidden_omniprobe_ctx` ABI,
- metadata/descriptor facts that are consistent with the rewritten clone.

The resulting artifact must remain compatible with Omniprobe's existing runtime
discovery, clone dispatch, kernarg repack logic, and `dh_comms` transport.

## Non-Goals for V1

The first implementation should not attempt to solve every instrumentation
problem at once.

Out of scope for the first landing:

- arbitrary inline user ISA injection
- arbitrary per-probe helper signatures
- generic state allocation/lifetime beyond the existing `runtime_ctx` pointer
- cross-kernel whole-program optimization of helpers
- architecture-agnostic binary rewriting for non-AMDGPU targets
- full parity for every historical LLVM pass selector on day one

V1 should focus on a narrow but complete path:

- `kernel_lifecycle_v1`
- `memory_op_v1`
- later `basic_block_v1` and `call_v1` after the first two are stable

## Current State

The repository already has most of the user-facing specification layer:

- `tools/probes/validate_probe_spec.py`
- `tools/probes/generate_probe_surrogates.py`
- `tools/probes/prepare_probe_bundle.py`
- `inc/omniprobe_probe_abi_v1.h`

The repository also already has most of the code-object rewrite substrate:

- inspection and normalized manifests under `tools/codeobj`
- editable instruction-level IR (`disasm_to_ir.py`)
- rebuild and regeneration tooling (`rebuild_code_object.py`,
  `regenerate_code_object.py`)
- donor-free clone insertion and hidden-ABI materialization
- cache preparation (`prepare_hsaco_cache.py`)
- runtime validation for hidden-kernarg repack and direct clone launch

What is missing is the bridge between those two subsystems:

- selecting binary probe sites from the YAML spec
- lowering those probe intents into code-object mutations
- linking generated surrogates and user helpers into the rebuilt code object
- rewriting the clone body so probe sites call those surrogates
- regenerating descriptors/metadata from the rewritten clone rather than merely
  cloning or preserving them

## Design Principles

### 1. One User Spec, Two Frontends

The YAML and helper contract must remain shared with the LLVM/source frontend.
Binary-only instrumentation is a new backend, not a new product surface.

The binary path should consume the same normalized probe spec and the same
surrogate manifest shape generated today by `prepare_probe_bundle.py`.

### 2. Surrogates Remain the Stable Injection Target

The binary rewriter should not inject direct calls to arbitrary user helper
functions.

It should inject calls only to generated surrogate functions, because that:

- stabilizes the call signature at each probe contract,
- isolates helper source changes from binary patch logic,
- keeps the pass-plugin and binary-only paths converged.

### 3. Hidden ABI Is the Converged Kernel ABI

The binary path should continue to materialize `hidden_omniprobe_ctx` in clone
metadata and descriptors. The injected surrogate call sequence should recover
the `runtime_ctx` pointer from that hidden argument rather than depending on an
explicit added kernel argument.

### 4. Binary-Only Injection Must Be Rebuild-Centric

The implementation should not begin with raw byte patching of final hsaco text
sections. Omniprobe already has a workable model based on:

- disassembly to instruction-level IR,
- structured mutation,
- AMDHSA assembly emission,
- `llvm-mc` + `ld.lld` rebuild,
- manifest/metadata regeneration.

The new functionality should extend that rebuild pipeline rather than create a
second, more brittle binary patcher.

### 5. Probe Site Logic Must Be Contract-Specific

Not every probe kind needs the same site-local capture logic.

The injector should be contract-driven:

- `kernel_lifecycle_v1`: capture timestamp and call entry/exit surrogate
- `memory_op_v1`: capture address, bytes, access kind, address space
- `basic_block_v1`: capture timestamp and stable block id
- `call_v1`: capture timestamp and stable callee id

This keeps the implementation coherent with `inc/omniprobe_probe_abi_v1.h`.

## End-to-End V1 Flow

```text
+--------------------+
| probe spec YAML    |
| helper HIP source  |
+---------+----------+
          |
          v
+-----------------------------+
| validate_probe_spec.py      |
| prepare_probe_bundle.py     |
+-------------+---------------+
              |
              v
+--------------------------------------+
| normalized probe spec +              |
| surrogate manifest + helper bitcode  |
+----------------+---------------------+
                 |
                 v
+--------------------------------------+
| code-object inspection               |
| + disasm -> instruction IR           |
+----------------+---------------------+
                 |
                 v
+--------------------------------------+
| binary probe planner                 |
| - resolve target kernels             |
| - resolve probe sites                |
| - plan clone ABI + helper linkage    |
+----------------+---------------------+
                 |
                 v
+--------------------------------------+
| binary probe mutator                 |
| - inject surrogate call sequences    |
| - materialize hidden ctx loads       |
| - preserve/repair CFG as needed      |
+----------------+---------------------+
                 |
                 v
+--------------------------------------+
| donor-free rebuild                   |
| - link helper/surrogate device code  |
| - regenerate clone metadata          |
| - regenerate clone descriptors       |
+----------------+---------------------+
                 |
                 v
+--------------------------------------+
| prepared cache artifact              |
| + Omniprobe runtime clone dispatch   |
+--------------------------------------+
```

## Proposed Implementation

## Phase 1: Make Probe Bundles Consumable by the Code-Object Path

### Objective

Turn today's probe bundle output into a first-class input for
`prepare_hsaco_cache.py`.

### Work

Add a new binary-only preparation mode that accepts a probe spec or an already
prepared bundle:

- `prepare_hsaco_cache.py --probe-spec spec.yaml`
- or `prepare_hsaco_cache.py --probe-bundle bundle.json`

The cache-prep flow should:

1. validate/generate the probe bundle if needed
2. inspect the input code object
3. determine the target architecture
4. compile helper HIP to target-specific device bitcode if the bundle is not
   already materialized
5. hand a normalized instrumentation package to the rewrite backend

### Files

- `tools/codeobj/prepare_hsaco_cache.py`
- `tools/probes/prepare_probe_bundle.py`
- new helper loader module under `tools/codeobj`

### Exit Criteria

- binary cache-prep can load a v1 probe bundle and report a structured
  instrumentation plan even before site injection is implemented
- the same YAML/helper assets used by the pass-plugin smoke tests are accepted
  by the binary-only path

## Phase 2: Add a Binary Probe Planning Layer

### Objective

Introduce a planning layer that maps normalized probe specs to concrete
code-object rewrite intents.

### Work

Create a new planner, for example `tools/codeobj/plan_probe_instrumentation.py`,
that operates on inspected manifests and instruction IR.

The planner should produce a machine-readable plan describing:

- selected source kernels
- clone names
- hidden ABI placement
- surrogate/helper symbols required by each kernel
- per-kernel probe sites
- per-site contract kind
- per-site capture requirements
- any unsupported selectors that force a fail-closed result

The planner should understand a constrained selector set for V1:

- kernel-name filtering from `target.kernels`
- `kernel_entry`, `kernel_exit`
- memory-op selection via mnemonic/opcode classes already visible in disasm
- later: basic-block and call targets

### Files

- new `tools/codeobj/plan_probe_instrumentation.py`
- shared selector helpers in `tools/codeobj/common.py`
- possibly small manifest extensions in `tools/codeobj/code_object_model.py`

### Exit Criteria

- planner can emit a deterministic JSON plan for `kernel_lifecycle_v1`
- planner can emit probe-site matches for `memory_op_v1` on representative test
  kernels
- unsupported selectors fail closed with explicit diagnostics

## Phase 3: Introduce Binary-Level Site Selection and IDs

### Objective

Resolve stable probe-site identities inside a rewritten clone.

### Work

For each supported contract:

- `kernel_lifecycle_v1`
  - define synthetic entry and exit sites
- `memory_op_v1`
  - classify load/store instructions in IR and assign stable per-kernel site IDs
  - map address-space classes to the shared ABI enum
- `basic_block_v1`
  - assign block IDs from CFG structure
- `call_v1`
  - identify direct call instructions and derive stable callee IDs

The planner output must be stable enough that a test can diff the plan across
no-op rebuilds of the same input.

### Key Constraint

Site numbering should be driven by Omniprobe's generated surrogate manifest
site IDs where possible, with a second per-kernel binary site identifier for
local patch placement. Do not let the binary path invent an unrelated helper ABI.

### Exit Criteria

- site planning is reproducible across repeated runs on the same input
- manifest/probe ID mapping is explicit in the plan output

## Phase 4: Build a Hidden-ABI Runtime-Context Lowering Primitive

### Objective

Give injected binary call sequences a reusable way to recover
`runtime_ctx`/`hidden_omniprobe_ctx`.

### Work

Introduce a small lowering library that knows how to generate the instruction
IR sequence needed to:

1. locate the hidden argument slot in the clone kernarg layout
2. compute the kernarg address of `hidden_omniprobe_ctx`
3. load the pointer value
4. prepare surrogate call arguments

This should be expressed at the instruction-IR layer, not as string splicing.

The lowering library must be architecture-aware enough to emit correct AMDGPU
address calculation sequences, but should isolate those details behind a small
interface so future backend-specific implementations can be swapped in.

### Files

- new `tools/codeobj/lower_probe_runtime_ctx.py`
- supporting helpers in `tools/codeobj/disasm_to_ir.py` and/or a new mutation
  utility module

### Exit Criteria

- hidden-ABI load sequence can be inserted into a no-op clone and reassembled
- direct launch still succeeds with runtime repack

### Current refinement

The lifecycle path should now be treated as two layers:

1. a kernel-specific binary thunk compiled from HIP/C++ that reconstructs the
   capture struct from `kernarg_base` and calls the shared generated surrogate
2. an ISA injector that only needs to marshal:
   - `runtime_ctx *`
   - `kernarg_base`
   - `timestamp`

This decomposition is important because observed AMDGPU device-call lowering is
similar across RDNA and CDNA at the `v0:v5` argument-marshalling level, but
varies in SGPR numbering and prologue shape. The injector should therefore stay
thin and backend-driven.

## Phase 5: Inject Surrogate Calls for `kernel_lifecycle_v1`

### Objective

Land the first end-to-end binary-only helper call path on the simplest
contract.

### Work

Implement contract-specific injection for kernel entry and exit:

- entry:
  - insert hidden-ctx load
  - capture timestamp
  - materialize capture struct for requested kernel args
  - call generated entry surrogate
- exit:
  - same, at every return path
  - preserve any kernarg-derived uniform values at entry rather than assuming
    the original kernarg SGPR pair is still live at `s_endpgm`

To make this robust, add a control-flow normalization pass for the clone only:

- optionally canonicalize multi-return kernels into a single exit block
- or replicate exit instrumentation before each return when structurally simpler

For V1, prefer the simpler strategy that produces reliable assembly with minimal
CFG surgery.

The current backend recommendation is to land `kernel_exit` injection before
`kernel_entry` injection:

- `kernel_exit` can usually marshal call arguments immediately before
  `s_endpgm`, where clobber pressure is easier to reason about, but only after
  entry-time saves have been introduced for any values that are no longer live
  at exit
- `kernel_entry` is more likely to overlap with system-value live ranges and
  therefore needs more careful save/restore and temporary-register policy

### Current Note

The first working binary-only lifecycle exit path now saves uniform
kernarg-derived values such as `hidden_omniprobe_ctx` and requested kernel
arguments into reserved SGPRs at function entry, then marshals those saved SGPRs
at `kernel_exit`.

That is sufficient for helpers whose logic depends only on uniform values and
the lifecycle timestamp. It is not yet sufficient for helpers that expect
late-available per-lane execution-context builtins such as `threadIdx` or other
values derived from wave VGPR state. Supporting those helpers in the binary-only
`kernel_exit` path requires an additional preservation mechanism for per-lane
context, most likely via private memory, LDS, or a dedicated carrier-side
context packet.

### Files

- new `tools/codeobj/inject_probe_calls.py`
- integration in `tools/codeobj/regenerate_code_object.py`
- integration in `tools/codeobj/prepare_hsaco_cache.py`

### Exit Criteria

- binary-only `kernel_timing_v1.yaml` produces a rewritten clone that launches
- Omniprobe routes dispatches to the clone
- instrumented clone emits `dh_comms` traffic attributable to entry/exit helper
  calls

## Phase 6: Link Generated Surrogates and Helper Device Code into Rebuilt Objects

### Objective

Ensure rebuilt code objects contain the actual surrogate/helper implementations
referenced by injected calls.

### Work

Add a link stage to the rebuild path that can combine:

- rebuilt clone assembly/object,
- generated surrogate/helper bitcode or object,
- any required device-runtime support symbols.

There are two plausible subpaths:

1. compile surrogates + helpers to relocatable AMDGPU object and link with the
   rebuilt code-object object
2. link at the LLVM bitcode/object level before final `ld.lld`

V1 should choose the simpler, more debuggable path even if it is less elegant.
The preferred starting point is:

- `prepare_probe_bundle.py` already emits helper bitcode
- add an explicit helper-object compilation step for the target arch
- feed that relocatable object into the final link

### Additional Requirements

- preserve symbol visibility needed by HIP/HSA lookup
- mark generated surrogate functions as retained
- avoid breaking original support sections or device library references

### Files

- `tools/probes/prepare_probe_bundle.py`
- `tools/codeobj/rebuild_code_object.py`
- `tools/codeobj/regenerate_code_object.py`

### Exit Criteria

- rebuilt code object resolves surrogate/helper symbols without donor-slot help
- direct module launch succeeds for the rewritten clone

## Phase 7: Inject Surrogate Calls for `memory_op_v1`

### Objective

Support the first dynamic site payload contract in the binary path.

### Work

For each selected memory instruction:

- compute the effective address from the instruction form
- derive byte width
- derive access kind
- derive address-space enum
- materialize capture struct for requested kernel args
- call generated memory-op surrogate

This work should be deliberately scoped.

For V1:

- start with global/flat scalar and vector load/store forms observed in current
  tests and rocPRIM sweep results
- make unsupported opcodes fail closed rather than guessed

Address reconstruction should reuse architecture-specific decode helpers rather
than open-coded mnemonic string matching wherever possible.

### Exit Criteria

- binary-only `memory_trace_v1.yaml` works on a controlled test kernel
- helper receives correct address/size/access/address-space values
- runtime emits data that matches the source/pass-plugin path for the same test

## Phase 8: Descriptor and Metadata Regeneration From Clone Facts

### Objective

Make rewritten clone descriptors authoritative after helper injection.

### Work

Once helper calls are inserted, clone resource facts may change:

- SGPR/VGPR usage
- scratch/private segment requirements
- user/system SGPR enables
- kernarg size
- call graph and text layout

The binary-only path must therefore stop relying on descriptor-byte reuse for
instrumented clones. Instead it should:

- rebuild the clone body,
- derive descriptor fields from the rebuilt clone,
- regenerate the clone's metadata entry from the same source of truth,
- preserve original descriptors only for untouched original kernels.

This is the line between "rewriter demo" and "real instrumentation."

### Exit Criteria

- injected clones launch without descriptor-byte preservation overrides
- clone metadata and descriptors agree on kernarg/resource facts

## Phase 9: Runtime Integration in Managed Cache

### Objective

Make binary-only probe instrumentation a normal Omniprobe managed-cache path.

### Work

Extend `prepare_hsaco_cache.py` and runtime metadata/reporting so cache artifacts
record:

- source kernel name
- clone kernel name
- probe bundle identity
- hidden ctx offset
- clone kernarg length
- instrumentation mode (`probe-binary-v1`)

Runtime discovery should not need a separate branch for probe-generated clones
versus donor-free no-op clones. It should see the same Omniprobe naming and
hidden-ABI conventions.

### Exit Criteria

- Omniprobe can prepare cache from an input hsaco plus YAML/helper pair and run
  the host application without source rebuilds
- logs clearly distinguish source/pass-plugin carriers from binary-generated
  probe clones

## Phase 10: Expand to `basic_block_v1` and `call_v1`

### Objective

Generalize after the first two contracts are stable.

### Work

Add:

- CFG-aware block ID allocation and injection
- direct-call identification and callee ID assignment
- helper examples and tests for these contracts in the binary path

These are intentionally later because they require more control-flow and symbol
reasoning than the first two contracts.

### Exit Criteria

- `basic_block_timing_v1.yaml` works on a structured test kernel
- `call_trace_v1.yaml` works on a kernel with direct device calls

## Implementation Structure

The work is best split across five owned components.

### A. Probe Bundle Ingestion

Owner files:

- `tools/probes/prepare_probe_bundle.py`
- `tools/codeobj/prepare_hsaco_cache.py`

Responsibilities:

- bundle generation
- helper compilation
- architecture resolution
- user-facing CLI

### B. Binary Probe Planning

Owner files:

- new `tools/codeobj/plan_probe_instrumentation.py`
- `tools/codeobj/common.py`

Responsibilities:

- selector resolution
- site matching
- clone instrumentation plan emission

### C. Injection Lowering

Owner files:

- new `tools/codeobj/inject_probe_calls.py`
- new lowering helpers under `tools/codeobj`

Responsibilities:

- hidden-ctx load sequences
- capture-struct materialization
- surrogate call sequence injection
- contract-specific site lowering

### D. Rebuild and Linking

Owner files:

- `tools/codeobj/rebuild_code_object.py`
- `tools/codeobj/regenerate_code_object.py`

Responsibilities:

- clone rebuild
- helper/surrogate linkage
- descriptor regeneration
- metadata regeneration

### E. Runtime Validation

Owner files:

- `tests/run_module_load_tests.sh`
- `tests/run_probe_helper_example_tests.sh`
- new binary-probe runtime tests

Responsibilities:

- direct launch validation
- managed-cache execution
- `dh_comms` output validation
- fail-closed coverage

## Suggested Milestone Order

1. Bundle ingestion in `prepare_hsaco_cache.py`
2. Planner JSON for lifecycle probes
3. Hidden-ctx lowering primitive
4. Lifecycle injection and direct launch test
5. Helper/surrogate link integration
6. Managed-cache runtime test for lifecycle
7. Memory-op site planner
8. Memory-op injection and runtime validation
9. Descriptor/metadata regeneration hardening
10. Basic-block and call contracts

This order gets one complete vertical slice working before widening coverage.

## Testing Plan

### Unit/Tooling Tests

- probe-spec validation remains under `tests/run_probe_spec_tests.sh`
- add planner snapshot tests for lifecycle and memory-op selections
- add helper bundle generation tests that exercise the binary-only CLI entry

### Direct Clone Launch Tests

Add direct code-object tests that:

- generate a probe bundle from YAML/helper examples
- rewrite a plain hsaco into an instrumented clone-bearing hsaco
- launch the clone directly with `test_hip_module_launch`
- validate expected `dh_comms` output or side effects

### Managed Cache / Runtime Tests

Extend `tests/run_module_load_tests.sh` to cover:

- binary-only lifecycle helper injection
- binary-only memory-op helper injection
- donor-free path with no source rebuild
- fail-closed behavior for unsupported selectors/opcodes

### Breadth / Stress Tests

- run rocPRIM breadth after lifecycle injection lands
- select a limited set of memory-op probes over rocPRIM kernels
- use the AITER MLA sample object as a structural audit and planner-eligibility
  target before enabling full runtime instrumentation there

## Primary Risks

### Risk 1: Site-Lowering Brittleness Across ISAs

Mitigation:

- centralize AMDGPU instruction classification and operand decoding
- fail closed on unsupported forms
- keep contract lowering factored away from the rest of the rebuild pipeline

### Risk 2: Helper Linkage Pulls in Unplanned Device-Runtime Dependencies

Mitigation:

- start with deliberately small helper examples
- inspect linked symbol sets in tests
- keep bundle compilation logs as first-class artifacts

### Risk 3: Descriptor Drift After Injection

Mitigation:

- make clone descriptor regeneration authoritative for injected clones
- preserve original kernel descriptors only for untouched kernels
- audit resource fields in tests

### Risk 4: Exit Injection on Complex CFGs

Mitigation:

- land lifecycle entry first if needed
- use controlled multi-return test kernels
- choose a conservative exit strategy before attempting aggressive CFG rewrites

### Risk 5: Overcoupling to One LLVM Revision

Mitigation:

- isolate architecture/codegen assumptions inside the lowering backend
- keep probe planning and runtime ABI independent of one exact backend revision
- capture known-good compiler/toolchain versions in test output and docs

## Definition of Done

This effort is complete when all of the following are true:

1. A user can point Omniprobe at a plain hsaco plus a v1 YAML/helper pair.
2. Omniprobe can generate a donor-free rewritten code object containing true
   instrumented clone kernels.
3. Those clone kernels inject calls to generated surrogates in the binary-only
   path, not just in the LLVM pass path.
4. The surrogate/helper code executes and emits data through `dh_comms`.
5. Runtime dispatch uses Omniprobe's normal clone discovery and hidden-kernarg
   repack path.
6. The same YAML/helper assets remain valid for both source and binary-only
   instrumentation frontends.

## Immediate Next Step

Implement Phase 1 and Phase 2 together:

- extend `prepare_hsaco_cache.py` to accept a probe spec/bundle,
- emit a binary instrumentation plan JSON,
- support `kernel_lifecycle_v1` target resolution first.

That is the smallest meaningful checkpoint because it creates the real frontend
contract for the remainder of the implementation.

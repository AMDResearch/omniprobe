# Code-Object Tooling

This directory is the first migration point for Omniprobe's binary-only
instrumentation path.

Current scope:

- `extract_bundle.py`
  - extracts AMDGPU ELF code objects from clang offload bundles
- `inspect_code_object.py`
  - emits a JSON manifest from an AMDGPU ELF code object
  - includes parsed kernel metadata, descriptors, helper-function inventory,
    and support-section payloads (`.data`, `.bss`, `.rodata`)
- `disasm_to_ir.py`
  - lowers AMDGPU disassembly into an editable instruction-level IR
  - records exact instruction encodings so unchanged instructions can be
    re-emitted byte-for-byte
- `mutate_ir.py`
  - applies small targeted edits to the instruction-level IR
  - clears the stale original encoding for edited instructions so they are
    reassembled from text during rebuild
- `analyze_descriptor_safety.py`
  - compares original and edited IR for one kernel and reports whether the
    original raw descriptor bytes still look safe to reuse
  - uses conservative checks around layout changes, widened explicit SGPR/VGPR
    usage, and descriptor-sensitive instruction edits
- `ir_to_asm.py`
  - renders the instruction-level IR back to plain AMDGPU assembly
- `emit_amdhsa_asm.py`
  - emits a full AMDHSA assembly file from IR plus manifest metadata
  - supports a hybrid `--exact-encoding` mode where unchanged instructions stay
    byte-exact while edited instructions are reassembled from text
  - supports `--preserve-descriptor-bytes` when a no-op exact rebuild must keep
    the original 64-byte kernel descriptors instead of letting the assembler
    recompute them
- `rebuild_code_object.py`
  - wraps assembly emission, `llvm-mc`, and `ld.lld` behind an explicit
    Omniprobe rebuild mode
  - supports `exact`, `abi-preserving`, and `abi-changing` contracts
  - gates `abi-preserving` rebuilds on descriptor-safety analysis and preserves
    descriptor bytes only when that analysis passes
  - also supports an explicit descriptor-byte preservation override for no-op
    orchestration paths that need Mode C packaging/reporting without trusting
    LLVM to reproduce every descriptor bit
- `analyze_rebuild_readiness.py`
  - conservative eligibility check for rebuild-mode orchestration
  - currently used to fail closed before `abi-changing` cache-prep rebuilds
    when the manifest lacks the descriptor count evidence needed for regenerated
    no-op rebuilds
- `audit_code_object_structure.py`
  - compares two inspected manifests for structural fidelity
  - can enforce exact descriptor-byte equality, exact metadata-note equality,
    and exact binding/visibility/section/type matches for selected symbols
- `plan_hidden_abi.py`
  - computes Omniprobe clone naming and a proposed `hidden_omniprobe_ctx`
    insertion point from a manifest
- `mutate_hidden_abi_kernel.py`
  - applies a minimal true ABI-changing mutation in place to one kernel
  - rewrites the metadata note to append `hidden_omniprobe_ctx` and patches the
    descriptor kernarg size accordingly
- `patch_code_object.py`
  - replaces one ELF section in a metadata-bearing donor object
- `rewrite_metadata_note.py`
  - rewrites the AMDGPU metadata note in-place when the replacement payload fits
    inside the existing note allocation
- `rebind_surrogate_kernel.py`
  - repurposes an existing donor kernel/descriptor slot as a hidden-ABI clone
    without growing alloc sections
  - now emits an optional JSON report describing the surrogate rewrite as an
    explicit `abi-changing` operation
- `prepare_hsaco_cache.py`
  - orchestrates manifest generation for standalone AMDGPU code objects and for
    host binaries/shared libraries containing bundled AMDGPU code objects
  - prefers existing real clone carriers when available, and otherwise falls
    back to hidden-ABI surrogate rewrite
  - can optionally run an explicit source rebuild step before cache generation;
    current cache-prep support is `--source-rebuild-mode exact` and a gated
    `abi-changing` path backed by descriptor-count evidence from the input
    manifest
  - current no-op `abi-changing` cache prep preserves original descriptor bytes
    and reports that override explicitly
  - emits a cache directory of clone-capable code objects for Omniprobe's
    runtime discovery path
  - annotates outputs with explicit rebuild-mode metadata:
    `exact` for carrier pass-through and `abi-changing` for surrogate rewrites
- `extract_code_objects.cpp`
  - extracts AMDGPU code objects from host binaries using the same kernelDB/HSA
    path used during runtime discovery
- `analyze_carrier_recipe.py`
  - compares an original kernel and its real instrumented clone inside a carrier
    code object
  - reports resource-metadata deltas, disassembly divergence windows, and
    symbols added versus an optional uninstrumented reference object
  - useful for deriving the next binary-patching steps from compiler-generated
    instrumentation artifacts
- `test_hsa_lookup.cpp`
  - minimal HSA code-object loader / symbol enumerator for validating kernel
    symbol visibility on non-HIP `.hsaco` files
  - useful for OpenCL-generated code objects where HSA exports descriptor
    symbols such as `copyA.kd`, while `hipModuleGetFunction("copyA")` is not
    a valid lookup path
- `test_hsa_launch.cpp`
  - minimal HSA dispatch harness for descriptor-symbol launches
  - allocates GPU buffers and kernargs directly from HSA memory pools
  - useful for validating execution of original and rewritten OpenCL-style
    code objects without going through the HIP module lookup path
- `test_hip_module_launch.cpp`
  - minimal `hipModuleLoad` / `hipModuleLaunchKernel` harness for standalone
    HIP-style code objects
  - useful for validating no-op and semantic rebuilds of simple extracted
    kernels without rebundling them into an executable first
- `test_hidden_kernarg_repack.cpp`
  - validates Omniprobe's runtime kernarg rewrite contract for hidden-ABI
    clones using real COMGR-parsed descriptors from source and clone code
    objects
  - useful for proving that source hidden args are preserved and
    `hidden_omniprobe_ctx` lands at the clone-owned slot before device-side
    helper injection is introduced

These tools are intentionally build-light. They establish an in-repo frontend
for code-object inspection and hidden-ABI planning while the full binary
instrumentation backend is still being migrated.

Current validated rebuild status on `trippy`:

- `simple_heatmap_test` extracted code objects can now be:
  - inspected into the richer manifest shape
  - lowered to editable IR
  - re-emitted as a fresh code object
  - loaded and executed again through `hipModuleLoad`
- a one-instruction semantic edit to that extracted kernel can be rebuilt into
  a fresh code object that still loads and changes runtime behavior
- `tests/run_codeobj_roundtrip_tests.sh` now scripts that exact simple path as a
  regression:
  - extract from `simple_heatmap_test`
  - rebuild a no-op equivalent code object and validate it
  - run descriptor-safety analysis on the simple store-operand mutation
  - apply the `0x114c` store-operand mutation and confirm runtime divergence
  - rebuild `module_load_kernel_plain.hsaco` with `--exact-encoding
    --preserve-descriptor-bytes` and validate the helper-heavy no-op round-trip
- helper-rich HIP device-runtime objects such as
  `module_load_kernel_plain.hsaco` now also no-op round-trip successfully when
  the exact rebuild path preserves:
  - original leading/inter-function text layout
  - undefined weak symbol stubs such as `blockIdx`
  - original raw kernel-descriptor bytes via `--preserve-descriptor-bytes`
- metadata-sensitive semantic edits on helper-rich objects are still the next
  pressure case; for those, descriptor/resource recomputation will need to be
  made selective instead of always preserving the original descriptor bytes

# Binary Probe Descriptor Audit

## Why this exists

Binary-only instrumentation currently rebuilds a clone kernel body by editing disassembly, linking in compiled probe support code, and then rewriting selected AMDHSA descriptor and metadata fields in the output code object.

The original implementation treated most descriptor changes as a resource-footprint problem:

- increase SGPR count
- increase VGPR count
- increase private segment size
- set dynamic-stack/private-segment bits when helper calls spill or allocate stack

That model is incomplete. Some descriptor fields are resource-allocation fields, but others describe the kernel-entry ABI that the command processor and firmware use to populate the initial SGPR/VGPR state before the first instruction executes.

If a helper path is compiled in a way that requests additional kernel-entry state that the source kernel did not request, simply patching counts or scratch size is not sufficient. The rewritten clone may launch, but the injected/helper path can read undefined state or interpret the wrong registers.

## Relevant descriptor layout

On ROCm/LLVM 7.2 the installed `llvm/Support/AMDHSAKernelDescriptor.h` defines the descriptor as:

- `group_segment_fixed_size`
- `private_segment_fixed_size`
- `kernarg_size`
- `kernel_code_entry_byte_offset`
- `compute_pgm_rsrc3`
- `compute_pgm_rsrc1`
- `compute_pgm_rsrc2`
- `kernel_code_properties` (16-bit)
- `kernarg_preload` (16-bit)

One subtlety here is that the current omniprobe inspector models bytes `56:60` as a single packed `raw_value`, but LLVM's descriptor type treats that region as two logical fields:

- low 16 bits: `kernel_code_properties`
- high 16 bits: `kernarg_preload`

That packing is still writable as a 32-bit quantity, but it should be understood as two logical subfields rather than one monolithic policy value.

## Two classes of descriptor data

### 1. Resource / occupancy / stack footprint

These are the fields that can legitimately grow when instrumentation adds code:

- `compute_pgm_rsrc1.granulated_wavefront_sgpr_count`
- `compute_pgm_rsrc1.granulated_workitem_vgpr_count`
- `private_segment_fixed_size`
- `kernel_code_properties.uses_dynamic_stack`
- in practice, `compute_pgm_rsrc2.enable_private_segment` when scratch-backed helper code is involved

These fields tell the runtime/firmware how many registers or how much scratch the kernel needs.

### 2. Kernel-entry ABI / initial register state

These fields affect what state exists when the kernel starts executing:

- `compute_pgm_rsrc2.enable_sgpr_workgroup_id_[xyz]`
- `compute_pgm_rsrc2.enable_sgpr_workgroup_info`
- `compute_pgm_rsrc2.enable_vgpr_workitem_id`
- `kernel_code_properties.enable_sgpr_dispatch_ptr`
- `kernel_code_properties.enable_sgpr_queue_ptr`
- `kernel_code_properties.enable_sgpr_dispatch_id`
- more generally, any field that changes which system registers the CP initializes for the kernel

These are ABI-shaping fields.

Changing them is not equivalent to "allocating more resources." They change what live kernel-entry state exists and where code expects to find it.

## What we observed with the mixed-memory repro

The failing `mixed_memory_kernel` source descriptor is narrow:

- workgroup ID X enabled
- no workgroup ID Y/Z
- no VGPR workitem ID enablement
- no dispatch pointer / queue pointer / dispatch ID

The simplified binary helper that directly calls `dh_comms::v_submit_address(..., args.runtime->dh_builtins)` remains compatible enough with that descriptor to regenerate and run.

The heavier branching helper does not.

To make this visible, we compiled wrapper kernels around the generated binary thunk source and inspected the wrapper descriptors. That gives a compiler-produced approximation of what initial state the support path wants when it is compiled as a kernel.

For the heavy helper, the wrapper descriptor requested additional entry-state beyond the source kernel:

- `compute_pgm_rsrc2.enable_sgpr_workgroup_id_y = 1`
- `compute_pgm_rsrc2.enable_sgpr_workgroup_id_z = 1`
- `compute_pgm_rsrc2.enable_vgpr_workitem_id = 2`

The source `mixed_memory_kernel` descriptor does not provide that state.

That means the failure is not only "the helper used more SGPRs" or "the helper needed more scratch." The compiled helper path is asking for extra kernel-entry builtin state that the original kernel never requested.

## Why this matters for binary-only rewriting

The rewritten clone keeps the original kernel body and its original expectations about entry state.

Because of that, omniprobe cannot freely import arbitrary descriptor policy from a compiler-generated wrapper kernel. Some descriptor changes are safe and necessary, but widening the kernel-entry ABI is much more dangerous:

- the original instructions were assembled assuming the source kernel's entry contract
- the injected path is linked in after the fact
- the original prologue/register assumptions are not recomputed from source by the compiler

So there are helper shapes that are fundamentally incompatible with a donor-free binary clone unless we either:

- constrain the helper contract so it does not request additional entry state, or
- move to a deeper recompilation strategy that can rederive the whole kernel-entry contract for the modified kernel, not just patch selected descriptor bytes

## Current engineering response

A fail-closed ABI guard now runs during support-wrapper inspection in `tools/codeobj/regenerate_code_object.py`.

The guard compiles/inspects the wrapper kernels and rejects regeneration when the support-wrapper descriptor requests additional kernel-entry state that the source clone descriptor does not provide. Today it specifically blocks additional:

- workgroup ID SGPR requirements
- workgroup info SGPR requirements
- workitem ID VGPR requirements
- dispatch/queue/dispatch ID SGPR requirements

This is intentionally conservative. It prevents a class of helpers from silently regenerating and then faulting later at runtime.

## Practical implication for `dh_comms`

This aligns with the mid-kernel `dh_comms` work already underway:

- snapshot-backed helper paths can be made to work when the compiled helper stays within the source kernel's entry-state contract
- helpers that allow the compiler to retain fallback builtin acquisition paths can implicitly request additional kernel-entry state
- those helpers need to be simplified, specialized, or compiled against a stricter contract if they are to be used in donor-free binary instrumentation

## Follow-on work

1. Tighten the helper contract for binary-only instrumentation so the compiler can prove that fallback live-builtin paths are unavailable.
2. Extend the descriptor audit to distinguish hard ABI deltas from softer advisory deltas such as scratch/private-segment policy.
3. Decide whether future donor-free work will keep the fail-closed contract model or move toward a whole-kernel recompile path that can safely regenerate the entire descriptor/prologue contract.

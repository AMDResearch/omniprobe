# Donor-Free Code-Object Regeneration Plan

## Goal

Replace donor-slot dependence in Omniprobe's binary-only instrumentation path
with whole-code-object regeneration that preserves original kernels and emits
true instrumented clone kernels into a rebuilt output code object.

The end state is:

1. inspect a source code object into a normalized internal model
2. mutate or rebuild targeted kernels
3. emit a fresh code object containing:
   - original kernels
   - Omniprobe clone kernels
   - regenerated descriptors
   - regenerated AMDHSA metadata
   - required support sections
4. feed that rebuilt artifact into Omniprobe's existing runtime dispatch flow

## Constraints

- The resulting clone ABI must remain compatible with Omniprobe's converged
  hidden/suffix ABI and runtime kernarg rewrite logic.
- The pass-plugin and binary-only paths must converge on the same surrogate
  manifest and helper ABI.
- Heavy kernels must be allowed to change descriptor-sensitive properties such
  as VGPR/SGPR usage, LDS usage, and kernarg size.
- Single-kernel code objects must be first-class inputs.

## Current Limitation

Today's binary-only fallback path in `tools/codeobj/rebind_surrogate_kernel.py`
repurposes an existing donor kernel slot. That works only when a donor exists
inside the copied artifact or an external carrier code object is available. It
fails on single-kernel inputs and couples correctness to policies about which
kernel entries may be sacrificed.

## Implementation Sequence

### M1. Normalized CodeObjectModel

Introduce a shared code-object model under `tools/codeobj` that explicitly
tracks:

- ELF/header summary
- sections
- symbols
- support sections
- kernel descriptors
- kernel metadata entries
- function inventory
- future clone intents

Exit criteria:

- `inspect_code_object.py` builds and emits this model without changing the
  existing JSON manifest shape
- the model can be loaded independently by future rebuild/orchestration tools

### M2. No-op Whole-Object Regeneration

Add a dedicated regeneration tool that reconstructs an equivalent code object
from the normalized model without donor rebinding.

Initial scope:

- preserve original kernel inventory
- preserve support sections required for launch
- preserve symbol identity/visibility/binding
- regenerate or preserve metadata coherently

Exit criteria:

- no-op rebuild launches for representative helper-light and helper-heavy
  objects
- structural audit passes against original inputs

### M3. True Clone Insertion

Extend the model and emitter so a new Omniprobe clone kernel can be inserted as
an additional kernel entry rather than by reusing an unrelated donor.

Exit criteria:

- rebuilt code object contains both original kernel and Omniprobe clone
- runtime clone selection works without donor-slot logic

### M4. Descriptor Regeneration for Clones

Make clone descriptor generation authoritative. Clone descriptors must be
rebuilt from actual clone facts rather than copied from the source kernel.

Tracked fields include:

- kernarg size/alignment
- VGPR/SGPR evidence
- private/group segment size
- hidden-arg-related system/user SGPR enablement

Exit criteria:

- ABI-changing clone kernels launch without descriptor-byte reuse

### M5. Metadata Regeneration for Clones

Emit clone metadata from the same source of truth as descriptor regeneration.

Exit criteria:

- clone metadata no longer depends on patching the original note payload
- metadata and descriptor facts agree

### M6. Probe Bundle Integration

Drive binary-only instrumentation from the existing probe bundle workflow:

- probe YAML
- helper HIP source
- generated surrogate manifest
- helper bitcode

Exit criteria:

- `prepare_hsaco_cache.py` can instrument a single-kernel hsaco with no donor
  slot by rebuilding a new code object with a true Omniprobe clone

### M7. Multi-kernel Preservation

Generalize the rebuild path to preserve non-target kernels and shared support
sections across realistic multi-kernel code objects.

Exit criteria:

- multi-kernel objects remain semantically complete after instrumentation

### M8. Policy Flip

Make whole-object regeneration the default binary-only instrumentation path and
demote donor-slot rebinding to explicit fallback/debug status.

Exit criteria:

- single-kernel binaries no longer fail with `no donor kernel available`
- donor-slot rebinding is no longer required for normal operation

## Testing Strategy

Each milestone should be validated with:

- structural audits via `tools/codeobj/audit_code_object_structure.py`
- direct launch validation where possible
- managed-cache execution through `tests/run_module_load_tests.sh`
- probe bundle smoke tests
- at least one single-kernel no-donor object
- at least one helper-heavy object
- rocPRIM breadth cases
- the AITER MLA single-kernel object fetched on demand

## Immediate Work Items

1. Add `CodeObjectModel` and integrate it into `inspect_code_object.py`.
2. Add a no-op whole-object regeneration command path.
3. Add a regression that exercises single-kernel no-donor inputs.
4. Add true clone insertion on top of the normalized model.

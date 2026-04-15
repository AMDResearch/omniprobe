# Donor-Slot Debug Handoff (2026-04-15)

This memo captures the current debugging state for donor-slot binary instrumentation in Omniprobe in case the interactive session is lost.

## Workspace state

- Local synced repo: `/Users/keithlowery/distest/omniprobe-sync`
- Remote working repo: `trippy:/home/klowery/omniprobe`
- Remote feature branch in use: `feature/hsaco-instrumentation-core`
- Local `HEAD`: `0b9aa74`
- Local worktree is dirty with many unrelated user changes. Do not revert unrelated files.

Current local `git status --short` at time of handoff:

```text
 M docs/binary-instrumentation-whitepaper.md
 M docs/hsaco-instrumentation-architecture.md
 M docs/usage.md
 M omniprobe/omniprobe
 M tests/run_all_tests.sh
 M tests/run_codeobj_roundtrip_tests.sh
 M tests/run_module_load_tests.sh
 M tests/run_probe_lifecycle_smoke_tests.sh
 M tests/run_probe_spec_tests.sh
 M tests/run_probe_surrogate_smoke_tests.sh
 M tests/test_kernels/CMakeLists.txt
 M tools/codeobj/README.md
 M tools/codeobj/emit_amdhsa_asm.py
 M tools/codeobj/emit_hidden_abi_metadata.py
 M tools/codeobj/inspect_code_object.py
 M tools/codeobj/plan_hidden_abi.py
 M tools/codeobj/prepare_hsaco_cache.py
 M tools/codeobj/rebind_surrogate_kernel.py
 M tools/codeobj/rebuild_code_object.py
 M tools/probes/README.md
 M tools/probes/generate_probe_surrogates.py
?? docs/donor-free-codeobj-regeneration-plan.md
?? tests/run_codeobj_external_regen_tests.sh
?? tests/test_kernels/module_load_donor_slot_kernel.hip
?? tools/codeobj/code_object_model.py
?? tools/codeobj/regenerate_code_object.py
?? tools/probes/prepare_probe_bundle.py
```

## User-visible goal

The immediate goal is to get Omniprobe to a truthful three-path state:

1. Pass-plugin / compile-time instrumentation works.
2. Donor-slot binary instrumentation works for hsacos that contain eligible donor slots.
3. Donor-free binary instrumentation exists as the longer-term path, even if it is not yet generally runtime-robust.

The current blocker is path 2. Donor-slot selection and cache generation logic are close, but the rebound surrogate hsaco is still not accepted by the HIP loader.

## What is already known to work

- `tests/run_codeobj_roundtrip_tests.sh` passed on `trippy`.
- `tests/run_module_load_tests.sh` had previously passed the non-donor-slot coverage on `trippy`, including:
  - donor-free structural/cache-prep checks
  - donor-slot fail-closed behavior when no donor exists
  - carrier runtime success
  - hidden-ABI carrier runtime success with real `dh_comms` traffic
- Omniprobe CLI forwards `--hsaco-surrogate-mode`.
- Carrier path is runtime-proven.
- Donor-free path is structurally proven, but not yet the general runtime answer for helper-heavy kernels.

## Test artifact added for donor-slot work

New donor-bearing test source:

- `tests/test_kernels/module_load_donor_slot_kernel.hip`

This test code object intentionally contains:

- original `mlk`
- original `mlk_d`
- only one unrelated explicit-suffix clone `__amd_crk_mlk_dPv`

Purpose:

- prove that Omniprobe can rebind an existing donor slot for `mlk` at binary level
- separate donor-slot mechanics from pass-generated carriers

Associated build/test plumbing:

- `tests/test_kernels/CMakeLists.txt` adds target `module_load_donor_slot_hsaco`
- `tests/run_module_load_tests.sh` includes donor-slot runtime coverage

## Current technical understanding

### 1. Donor-slot selection was tightened

Initial donor selection was too permissive and treated unrelated instrumented kernels as donors. The current logic was tightened to require explicit suffix ABI compatibility. That matters because reusing a donor body with hidden-ABI metadata caused runtime faults.

### 2. First donor-slot rewrite approach was incorrect

The earlier rewrite path tried to force donor bodies into the hidden-ABI layout. That produced immediate GPU memory faults. The revised direction preserves the donor's explicit suffix ABI and only rebinds it to the source kernel's logical identity.

### 3. The failure is now loader validity, not runtime dispatch selection

Omniprobe runtime does find the surrogate:

- `Found instrumented alternative for mlk.kd`

But direct `hipModuleLoad` of the rebound donor-slot hsaco still fails with:

- `no kernel image is available for execution on the device`

That means the current blocker is the rewritten hsaco itself, not the Omniprobe cache-selection logic.

### 4. The strongest clue is malformed metadata note rewriting

Repeated `llvm-readelf --notes` inspection on rebound donor-slot hsacos shows:

- `unable to read notes from the SHT_NOTE section with index 1: ELF note overflows container`

That warning persists even when the rest of the ELF looks nearly identical to the original donor-bearing hsaco. This strongly suggests that metadata note replacement is still corrupting the file.

## Most important local-only change at interruption

The latest local patch was in:

- `tools/codeobj/rebind_surrogate_kernel.py`

This patch was applied locally but had not yet been validated on `trippy` at the time of handoff.

### Intent of the patch

The previous code was using rendered metadata text from the manifest as if it were the original note payload. That is almost certainly wrong for raw note replacement, and it likely explains oversized or malformed note contents.

The new patch does the following:

- adds `extract_original_note_text(...)`
- reads the actual `.note` descriptor bytes from the ELF
- decodes those bytes when they are legacy YAML text
- feeds the exact original note text into replacement logic
- falls back to reconstructed metadata only if exact note text is unavailable
- keeps donor-slot clone naming on the legacy explicit suffix ABI path
- tries to reuse existing string table slots before growing `.dynstr` / `.strtab`

### Key code-level changes currently present locally

- `build_legacy_replacement_metadata_payload(...)` now accepts `original_note_text`
- `extract_original_note_text(...)` extracts and decodes note desc bytes via `rewrite_metadata_note.find_amdgpu_note(...)`
- `clone_name` in donor-slot mode now uses `plan["legacy_explicit_clone_name"]`
- report output marks:
  - `"abi_layout": "legacy-explicit-suffix"`
- donor report currently records donor kernarg size instead of hidden-ABI length

This patch is meant to eliminate the bad assumption that `manifest["kernels"]["metadata"]["rendered"]` can be reused as the exact note payload.

## Why the note path is the main suspect

The donor-slot rewrite had already been narrowed substantially:

- symbol renaming was updated to reuse existing string slots where possible
- descriptor sizing changes were removed from the donor-slot path
- donor-slot path now tries to preserve the donor explicit suffix ABI

After those changes, the dominant remaining structural anomaly was still the note overflow warning. That makes `replace_metadata_note()` and the exact payload fed into it the highest-value place to debug.

## Files most relevant to the blocker

- `tools/codeobj/rebind_surrogate_kernel.py`
- `tools/codeobj/rewrite_metadata_note.py`
- `tools/codeobj/prepare_hsaco_cache.py`
- `tools/codeobj/inspect_code_object.py`
- `tests/test_kernels/module_load_donor_slot_kernel.hip`
- `tests/run_module_load_tests.sh`

## Validation sequence to resume with

The first thing to do after reconnecting is validate the newest local patch on `trippy`.

### 1. Sync `rebind_surrogate_kernel.py` to `trippy` if needed

Make sure the remote copy includes:

- `extract_original_note_text(...)`
- `original_note_text` threaded into `build_legacy_replacement_metadata_payload(...)`

### 2. Sanity check Python syntax

Run:

```bash
cd /home/klowery/omniprobe
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile tools/codeobj/rebind_surrogate_kernel.py tools/codeobj/rewrite_metadata_note.py tools/codeobj/prepare_hsaco_cache.py
```

### 3. Regenerate the donor-slot surrogate

Run:

```bash
cd /home/klowery/omniprobe
PYTHONDONTWRITEBYTECODE=1 python3 tools/codeobj/prepare_hsaco_cache.py \
  --output-dir /tmp/donor_slot_reuseX \
  --surrogate-mode donor-slot \
  build-hsaco-core/tests/test_kernels/module_load_donor_slot_kernel.hsaco
```

Expected outputs include:

- `/tmp/donor_slot_reuseX/module_load_donor_slot_kernel.mlk.kd.surrogate.hsaco`
- `/tmp/donor_slot_reuseX/module_load_donor_slot_kernel.carrier.hsaco`

### 4. Inspect the rewritten note

Run:

```bash
cd /home/klowery/omniprobe
/opt/rocm/llvm/bin/llvm-readelf --notes /tmp/donor_slot_reuseX/module_load_donor_slot_kernel.mlk.kd.surrogate.hsaco
```

Critical question:

- did `ELF note overflows container` disappear?

If the warning remains, the next debugging target is the raw note rewrite implementation in `rewrite_metadata_note.py`.

### 5. Directly test HIP loader acceptance

Run:

```bash
cd /home/klowery/omniprobe
build-hsaco-core/tools/test_hip_module_launch \
  /tmp/donor_slot_reuseX/module_load_donor_slot_kernel.mlk.kd.surrogate.hsaco \
  __amd_crk_mlkPv \
  index
```

Success criteria:

- `hipModuleLoad` succeeds
- kernel launch succeeds

If `hipModuleLoad` still reports `no kernel image is available for execution on the device`, donor-slot is still not ready to claim as supported.

### 6. If direct load succeeds, validate through Omniprobe runtime

Run the donor-slot module-load path through Omniprobe:

```bash
cd /home/klowery/omniprobe
BUILD_DIR=/home/klowery/omniprobe/build-hsaco-core bash -lc 'source tests/test_common.sh; check_omniprobe >/dev/null; OUT=/tmp/donor_slot_runtime.out; CACHE=/tmp/donor_slot_runtime.cache; LD_LIBRARY_PATH="${OMNIPROBE_ROOT}/lib:${LD_LIBRARY_PATH}" "$OMNIPROBE" -i -a Heatmap --hsaco-input "$BUILD_DIR/tests/test_kernels/module_load_donor_slot_kernel.hsaco" --cache-location "$CACHE" --hsaco-surrogate-mode donor-slot -- "$BUILD_DIR/tests/test_kernels/module_load_test" "$BUILD_DIR/tests/test_kernels/module_load_donor_slot_kernel.hsaco" >"$OUT" 2>&1; status=$?; echo STATUS=$status; sed -n "1,260p" "$OUT"'
```

Then rerun:

```bash
cd /home/klowery/omniprobe
BUILD_DIR=/home/klowery/omniprobe/build-hsaco-core tests/run_module_load_tests.sh
```

## If the note overflow persists

Debug `tools/codeobj/rewrite_metadata_note.py` directly.

Specific checks to perform:

- compare original note desc byte count vs rewritten desc byte count
- confirm desc padding and note record sizing are consistent
- verify section size updates and any program header updates touching `.note`
- inspect whether `replace_metadata_note()` writes a mismatched header or leaves trailing garbage
- compare the original donor-bearing hsaco note bytes with the rebound hsaco note bytes

The key question is whether the note container math is wrong or whether the replacement payload itself is malformed.

## Bottom line

The donor-slot path is not dead, but it is not yet working end-to-end. The current evidence points to a focused ELF metadata-note rewrite bug, not a broad failure of surrogate selection or dispatch redirection. The newest local patch is specifically aimed at fixing that bug by sourcing replacement text from the original note bytes instead of manifest-rendered metadata.

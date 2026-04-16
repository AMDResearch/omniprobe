# Refactor: Exact-Architecture Bitcode Selection

## Status
- [x] TODO
- [ ] In Progress
- [ ] Done

## Objective
Replace the two-bucket (cdna2/cdna3) bitcode selection in the instrumentation plugins with
exact-architecture bitcode loading. This eliminates the wave64/wave32 incompatibility that
prevents omniprobe from working on RDNA GPUs, and removes the need for architecture-bucket
maintenance as new GPU families are added.

## Motivation

The current approach compiles two bitcode variants of `dh_comms_dev.h`:
- **cdna2** (gfx90a): used for all pre-MI300 CDNA hardware
- **cdna3** (gfx942): used for MI300 variants (has XCC ID inline asm)

The `target-cpu` attribute is stripped from the bitcode so it can be linked into modules
targeting other architectures within the same wave-size family. This works within CDNA
(all wave64) but fails for RDNA (wave32): linking wave64 bitcode into a wave32 module
causes runtime failures in the pass-generated instrumentation path.

Keith Lowery's dh_comms PR #18 (merged 2026-04-15) added exact-arch bitcode generation
driven by `CMAKE_HIP_ARCHITECTURES`. This refactor completes the picture by updating the
instrumentation plugin to load the exact-arch bitcode, then removing the legacy
cdna2/cdna3 generation.

### Additional motivation
- The `#ifdef` chain in `data_headers_dev.h` (lines 68-88) hits `#error` for any
  architecture not explicitly listed (e.g., all RDNA variants). Exact-arch compilation
  needs this to be extended or restructured.
- Eliminates the growing maintenance burden of adding new architecture buckets
  (cf. PR #17 / Issue #16 discussion about CDNA1 bitcode).

## Refactor Contract

### Goal
1. Change `getBitcodePath()` to construct `dh_comms_dev_<arch>_co{5,6}.bc` using the
   module's detected architecture, falling back to cdna2/cdna3 for backward compatibility.
2. Update the `copy_bitcode` target to copy exact-arch bitcode files from dh_comms.
3. Remove the hardcoded cdna2/cdna3 bitcode generation from dh_comms `CMakeLists.txt`,
   keeping only the `CMAKE_HIP_ARCHITECTURES`-driven loop from PR #18.
4. Extend the `#ifdef` chain in `data_headers_dev.h` to support RDNA architectures
   (or restructure to a more maintainable pattern).

### Non-Goals / Invariants
- **No behavioral change for CDNA users** — existing CDNA workflows produce identical output
- **No API changes** — `omniprobe` CLI and handler interfaces unchanged
- **No changes to dh_comms runtime library** — only bitcode generation and selection

### Verification Gates
- **Build**: `cmake --build build` succeeds (gfx90a)
- **Tests**: `tests/run_all_tests.sh` — all suites pass
- **Correctness**: `omniprobe -i -a MemoryAnalysis -- <test>` output unchanged vs baseline
- **File list**: only exact-arch `.bc` files in `build/lib/bitcode/`, no cdna2/cdna3 files

## Scope

### Affected Files

| File | Change | Status |
|------|--------|--------|
| `src/instrumentation/InstrumentationCommon.cpp` | Rewrite `getBitcodePath()` to use `dh_comms_dev_<arch>` naming | confirmed |
| `tests/test_kernels/CMakeLists.txt` | Update `copy_bitcode` to copy arch-specific `.bc` files | confirmed |
| `external/dh_comms/CMakeLists.txt` | Remove hardcoded cdna2/cdna3 bitcode commands; keep PR #18 loop only | confirmed |
| `external/dh_comms/include/data_headers_dev.h` | Extend `#ifdef` chain for RDNA archs (or restructure) | confirmed |
| `external/dh_comms/include/gpu_arch_constants.h` | Add RDNA L2 cache line sizes and arch constants | hypothesis |
| `external/dh_comms/include/message.h` | Extend `gcnarch` enum with RDNA entries | hypothesis |

### Current Flow (InstrumentationCommon.cpp:46-118)

```
1. Detect target-cpu from module metadata or function attributes → arch string
2. Map arch to bucket:
     gfx940/941/942 → "_cdna3"
     everything else → "_cdna2"
3. Determine code object version:
     plugin path contains "triton" → "_co5"
     else → "_co6"
4. Construct path: <bitcode_dir>/dh_comms_dev<bucket><co_version>.bc
```

### Target Flow

```
1. Detect target-cpu from module metadata or function attributes → arch string
2. Determine code object version (same logic)
3. Try exact-arch path: <bitcode_dir>/dh_comms_dev_<arch>_<co_version>.bc
4. If not found, fall back to bucket:
     gfx940/941/942 → "_cdna3"
     everything else → "_cdna2"
   (backward compat for installs that only have legacy bitcode)
5. If fallback also not found → error
```

### dh_comms CMakeLists.txt: Current State (post PR #18)

The CMakeLists.txt currently generates **both** legacy and exact-arch bitcode:
- Legacy: hardcoded cdna2 (gfx90a) + cdna3 (gfx942), always built
- Exact-arch: loop over `CMAKE_HIP_ARCHITECTURES`, strips `:sramecc+:xnack-` suffixes

The refactor removes the hardcoded legacy commands, keeping only the loop.

### Risks

1. **RDNA `data_headers_dev.h` support** — The `#ifdef` chain and `gcnarch` enum only
   cover CDNA architectures. RDNA compilation will hit `#error`. This needs extending
   before exact-arch bitcode for RDNA can work. This is a dh_comms change.
2. **Wave size in inline asm** — The `s_getreg_b32 hwreg(HW_REG_HW_ID)` instruction
   (line 64) may have different register layouts on RDNA. Needs verification.
3. **Backward compatibility** — Users with existing installs that only have cdna2/cdna3
   bitcode need the fallback path to keep working until they rebuild.
4. **CI impact** — CI containers may not have RDNA in `CMAKE_HIP_ARCHITECTURES`. The
   exact-arch loop produces whatever was requested; CDNA-only CI still works.

## Plan of Record

### Micro-steps

1. [ ] **Baseline: capture test output** — Gate: none (research)
   - Run `omniprobe -i -a MemoryAnalysis` on a test kernel, save output for comparison

2. [ ] **Rewrite `getBitcodePath()` to try exact-arch first** — Gate: build + tests
   - Change `InstrumentationCommon.cpp`: construct `dh_comms_dev_<arch>_<co>.bc` path
   - If file exists, use it; else fall back to cdna2/cdna3 bucket
   - At this point both naming schemes coexist in the build tree

3. [ ] **Update `copy_bitcode` target** — Gate: build
   - `tests/test_kernels/CMakeLists.txt`: glob or list exact-arch `.bc` files from
     `${DH_COMMS_LIB_DIR}` instead of hardcoded cdna2/cdna3 names
   - Must handle variable file list driven by `CMAKE_HIP_ARCHITECTURES`

4. [ ] **Remove legacy cdna2/cdna3 generation from dh_comms** — Gate: build + tests
   - `external/dh_comms/CMakeLists.txt`: remove the hardcoded cdna2/cdna3 compilation
     commands, keep only the `CMAKE_HIP_ARCHITECTURES` loop from PR #18
   - Remove `REMOVE_DUPLICATES` (no longer needed without overlap)
   - Commit as a dh_comms PR

5. [ ] **Remove fallback path from `getBitcodePath()`** — Gate: build + tests
   - Once legacy generation is gone, the fallback is dead code
   - Clean up to only use `dh_comms_dev_<arch>_<co>.bc` naming

6. [ ] **Extend dh_comms for RDNA** (separate PR, may defer) — Gate: build on RDNA
   - `data_headers_dev.h`: add `#elif defined(__gfx1100__)` etc. (or restructure)
   - `gpu_arch_constants.h`: add RDNA L2 cache line sizes
   - `message.h`: extend `gcnarch` enum
   - This step enables RDNA instrumentation end-to-end but may be done by Keith

7. [ ] **Run full test suite + compare output** — Gate: all tests pass, output matches

8. [ ] **Update KT** — Gate: none
   - Update `architecture.md` and `sub_dh_comms.md` (if it exists)
   - Update this dossier status to Done

### Current Step
TODO — not yet started.

## Design Decisions

1. **Try exact-arch first, fall back to bucket** — During transition, both naming schemes
   may exist. Trying exact-arch first ensures new builds get the right bitcode while
   old installs still work. Once legacy generation is removed, the fallback becomes
   dead code and is cleaned up in step 5.

2. **Keep `target-cpu` stripping in dh_comms** — PR #18 strips `target-cpu` from the
   exact-arch `.ll` files (same as legacy). This is still useful: the bitcode is compiled
   *for* a specific arch (getting the right `#ifdef` branches, wave size, etc.) but the
   `target-cpu` attribute is removed so the LLVM linker doesn't reject it when linking
   into a module that may have a slightly different target string (e.g., `gfx90a` vs
   `gfx90a:sramecc+:xnack-`).

3. **Defer RDNA `data_headers_dev.h` changes** — Step 6 may be done by Keith (who has
   RDNA hardware and is actively working on RDNA support). The rest of the refactor
   (steps 1-5) is valuable on its own for cleaner architecture and eliminating the
   bucket maintenance burden.

## Rejected Approaches

1. **Keep the two-bucket model and just add RDNA buckets** — Scales poorly. Each new GPU
   family would need a new bucket, new `#ifdef` in `getBitcodePath()`, new hardcoded
   compilation commands. The exact-arch approach driven by `CMAKE_HIP_ARCHITECTURES`
   is self-maintaining.

2. **Generate bitcode for all known architectures unconditionally** — Wasteful. Most users
   target 1-2 architectures. The `CMAKE_HIP_ARCHITECTURES`-driven approach builds only
   what's needed.

## Related

- dh_comms PR #18: "Generate exact-arch device helper bitcode" (merged 2026-04-15)
- dh_comms PR #17 / Issue #16: CDNA1 bitcode discussion (closed — cdna2 bitcode works)
- `getBitcodePath()`: `src/instrumentation/InstrumentationCommon.cpp:46-118`
- Bitcode copy target: `tests/test_kernels/CMakeLists.txt:16-33`

## Open Questions

1. Does `s_getreg_b32 hwreg(HW_REG_HW_ID)` work on RDNA, or does it have a different
   register layout? (Relevant for step 6, may be answered by Keith's work.)
2. Should the `gcnarch` enum be renamed to something GPU-family-neutral (e.g., `gpuarch`)
   now that RDNA is in scope? Low priority but cleaner long-term.

## Last Verified
Commit: cd4c2f4
Date: 2026-04-16

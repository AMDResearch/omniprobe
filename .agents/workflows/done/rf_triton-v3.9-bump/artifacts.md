# Artifacts — rf_triton-v3.9-bump (2026-11-08, gfx90a/MI210, ROCm 7.2.0, Python 3.12)

## Survey risks (report § G) — what materialised

| Risk | Outcome |
|---|---|
| LLVM 23 → 24 (R2, `-Werror` breakage) | **Did not materialise.** Both plugin variants and the core compiled clean against b010a18d with no source change. Plugins now link `.so.24.0git` (R7: a mismatch fails loudly — it did, see below). |
| nanobind 2.10.2 (R4) | **Pre-empted** (`8f49b37`): `triton_install.sh` installs `nanobind==2.10.2`. Not tested without it. |
| Python ≥ 3.11 | **Pre-empted** (`8f49b37`): floor raised in `triton_install.sh`. Local venv is 3.12; no effect here. |
| #10849 keeps the TargetMachine (R1) | **Behaviour unchanged; codegen changed slightly.** See comparison below. |
| Subarch triple #11532 (R6) | **Live and handled.** Module triple is now `amdgpu9.0a-amd-amdhsa`; omniprobe logs `device function module found for amdgpu9.0a-amd-amdhsa` (`e6db747` match). |
| Three LLVMs (R3) | No incompatibility observed (dh_comms bitcode from ROCm clang, core LLVM 24, codegen LLVM 6bc4aaf6). |
| Configure-time download (R5) | The AMD codegen library was downloaded during the local build (present in the venv). Not exercised in CI yet. |

**Not predicted, and fixed:**
1. The Triton wheel does not link against a shared-library LLVM: v3.9.0's `TritonAMDMIRDAG` calls
   `llvm::createMIRParser` but links only `LLVMCodeGen` (`triton-opt`, `triton-reduce`, `triton-lsp`,
   `triton-tensor-layout` fail with undefined `llvm::MIRParser` symbols). `triton_install.sh` now
   patches the library in (`5eba213`). Upstream defect, not reported upstream (no external writes).
2. Re-configuring an existing build tree with a new `-DTRITON_LLVM` kept the old LLVM (cached
   `find_program`), so `build/` still produced a `.so.23.0git` plugin that Triton v3.9.0 could not
   load (`664c417`). Fails-before shown: reconfigure → `libLLVMCore.so.23.0git`; after the fix →
   `.so.24.0git`.
3. The Triton suite ignored `BUILD_DIR` (`f48753c`), so a run against a scratch tree tested `build/`.

## Instrumented output, v3.8.0 vs v3.9.0

Harness (untracked, node-local): three kernels — masked vector add (ragged size), `tl.dot` matmul
(LDS), row softmax (reductions) — under `-i -a AddressLogger -t json` and `-i -a MemoryAnalysis -t
json`, fresh `TRITON_CACHE_DIR` per run. Baseline determinism: two v3.8.0 runs give identical
trace summaries and byte-identical `.amdgcn`.

- **AddressLogger**: per (kernel, line, column, op, space, size) — record count, active lanes,
  distinct addresses, address-offset set — **identical** for all 16 groups. Only difference: four
  line numbers inside Triton's own `language/standard.py` (191→216, 293→314), which are the same
  `core.reduce(...)` source lines moved in the library.
- **MemoryAnalysis JSON**: **identical** after normalising dispatch_id (shifted by one: one fewer
  non-Triton dispatch earlier), timestamps, and those `standard.py` paths/lines.
- **ISA**: no calls in either (`s_swappc` 0 → dh_comms still inlined); instruction totals within
  0.2% (add 7075→7089, mm 70204→70262, softmax 9816→9823); VGPRs equal or lower (mm 50→48). Some
  16-bit dispatch-packet reads moved from `s_load_dword`+`s_lshr` to `global_load_ushort`, and the
  e32/e64 encoding mix shifted. Whether that comes from #10849 (TargetMachine) or from the new
  codegen LLVM was not isolated [inf].
- Bitcode selection unchanged: still "Could not determine target architecture, defaulting to
  cdna2" for Triton modules. New fact for `rf_exact-arch-bitcode`: the triple now carries the
  arch (`amdgpu9.0a`).

## Suites

Scratch tree (LLVM 24) + Triton v3.9.0: 19/20, the Triton suite failing only because it loaded
`build/`'s v3.8.0 plugin (fix 3); Triton suite then 6/6 on the scratch tree. `build/` reconfigured
(fix 2), env repointed: **20/20, 0 skipped**.

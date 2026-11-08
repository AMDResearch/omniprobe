# Run Log: rf_exact-arch-bitcode

## 2026-11-08 (opimpl worker, gfx90a node, supervised run)

- Resumed (`05ffd8c`); spec changes under D2 recorded in the dossier.
- Finding: dh_comms has no gfx950. `data_headers_dev.h` sets `gcnarch` from `__gfx<N>__` macros
  for gfx906/908/90a/940/941/942; its `#elif !defined(__host__) #error` never fires (HIP defines
  `__host__` as a macro), so a gfx950 device compile succeeds and every message reports
  `unsupported` (measured: no pragma, no error for `--offload-arch=gfx950`). MemoryAnalysis then
  skips cache-line analysis (`memory_analysis_handler.cc:403`, message only with verbose).
- Wrote `tests/test_bitcode_selection.sh` first: 0/5 on the unfixed build (logs in
  `.untracked/rf_exact-arch-bitcode/before/`), incl. the Triton triple case printing
  "Could not determine target architecture, defaulting to cdna2".
- Merged PR #38 (`0ed8fa4`, lwitschen's `7f88ad6` intact; superseded CMake hunk resolved to main).
- Follow-up `6acf90f`: exact-arch with legacy fallback + warning, identified-arch allowlist,
  triple-derived arch. Suite 25 added. 5/5 on gfx90a.
- Drafted dh_comms gfx950 patch (`.untracked/rf_exact-arch-bitcode/dh_comms-gfx950.patch`, not
  applied): enum gfx950 = 7, 128-byte L2 line, `__gfx950__` branch, XCC_ID read for gfx950.
  Compiles for gfx950 (pragma fires; assembler accepts `hwreg(HW_REG_XCC_ID)`).
- gfx950 runtime validation prepared: worktree `.untracked/wt-gfx950` (at `6acf90f`), build
  cross-compiled with `CMAKE_HIP_ARCHITECTURES=gfx950`; script `.untracked/gfx950-validation/run.sh`.
- Clean parallel cross-build for gfx950 failed: `No rule to make target
  lib/plugins/libAMDGCNSubmitBBInterval-rocm.so` (from `ad19235`'s OBJECT_DEPENDS without matching
  target ordering). Deterministic repro: clean tree, `--target bb_counts_test` -> rc 2 before,
  rc 0 after `1ec32b4`. gfx950 tree then built clean (all 16 plugin compiles: gfx950 from
  target-cpu, cdna2 bitcode with the "dh_comms does not identify" warning).
- Full suite gfx90a: 25/25 at `6acf90f` and again at `1ec32b4` (4m37s). Real Triton compiles
  (tests/triton/test_output): "Detected architecture: gfx90a (from target triple
  amdgpu9.0a-amd-amdhsa)", linked `dh_comms_dev_gfx90a_co5.bc`.
- Side finding (unverified against the ISA PDF): CDNA4 LDS reportedly has 64 banks;
  `memory_analysis_handler.cc:39` hardcodes 32. Notes in
  `.untracked/rf_exact-arch-bitcode/gfx950-lds-banks.md`. Not in this packet's scope.

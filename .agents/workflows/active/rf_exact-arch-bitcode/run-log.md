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

## 2026-11-08, later (supervisor ruling: Rene chose option C; LDS banks "verify and fix now")

- PR #38 comment posted (approved text).
- Prep for the MI350 run, all on local branch `mi350-prep` in `.untracked/wt-gfx950` (not pushed):
  dh_comms gfx950 commit `9551a41` on local submodule branch `gfx950` (not pushed); gfx950 joins
  the plugin's exact-arch list; MemoryAnalysis LDS model per architecture (gfx950 placeholder:
  64 banks, 64-lane phases for <=4 B, 32-lane for 8 B, to be set by measurement); suite 26.
- Measured on gfx90a: SQ_LDS_BANK_CONFLICT per wave per instruction equals the handler's
  conflict count exactly (b32 stride 2 -> 2, stride 32/64 -> 62, b64 stride 2 -> 4, stride 16
  -> 60, all controls 0, reads and writes alike). Omniprobe equals it for all 26 pattern kernels.
  The three hypotheses (32 banks/32-lane, 64/32-lane, 64/64-lane) each differ on >=1 pattern.
- Bug caught on the way: the first per-arch version used function-local statics; omniprobe
  then died with SIGSEGV at exit and lost the last dispatch (rc 139, 25 of 26 in the JSON;
  main: rc 0, 26). Never-destroyed models: 5/5 clean. Which of init race
  (-fno-threadsafe-statics) or destruction at exit caused it was not isolated.
- Worktree has build_gfx950 and build_gfx90a (both from mi350-prep), `build` symlinks to one.
  Branch suite on gfx90a: 23/26 in the first run; the 3 failures were prebuilt, gitignored
  rocBLAS/hipBLASLt test binaries absent from the worktree (copied; 3/3 then pass).
- `.untracked/gfx950-validation/run.sh` rewritten: LDS suite first, then full suite.

## 2026-11-08, last MI210 turn

- `0e257bc` tests/lds_conflict_sets (Rene's pairwise method). gfx90a control, ~15 s: b32 two
  32-lane sets, b64 four 16-lane, b128 reads {0..3,20..23}-style, 32 banks (128-byte sweep);
  one-process-per-pair spot checks equal the in-process sweep. **b128 writes: 8 consecutive
  lanes**, not the read grouping (confirmed one process per pair).
- `8d7f35d` handler: separate read/write phase groups (fixes b128 write counts), per-arch lookup;
  suite 26 on main with b128 patterns. Fails before: write_b128_rwsplit hw 8 vs omniprobe 0.
- `8e18d9e` -d random: actual mechanism is per-dispatch probability 1/100 after -k (not a draw
  over excluded dispatches); now warns per kernel it captured nothing of; docs corrected.
  Suite 27 fails before (captured=0, warned=0). Full suite 27/27, pushed with `9fc83ea`.
- MI350 branch is now `mi350` (`21764ce`, on main): dh_comms 9551a41 + gfx950 exact-arch +
  cdna4_lds placeholder. Dry run on gfx90a: 27/27. run.sh step (0) runs the conflict-set sweep.

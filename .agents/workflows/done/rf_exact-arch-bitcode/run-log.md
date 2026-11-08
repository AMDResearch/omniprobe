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

## 2026-11-08, MI350 node (gfx950, 1 GPU VM, fuseblk /work1; ROCR_VISIBLE_DEVICES=0)

- run.sh first pass: conflict-set sweep OK (spot checks equal); suite 26 failed under the
  placeholder (14/32 differ); faulted-dispatch failed (bare fault_test itself exits 141 here).
- Measured gfx950 map: b32 r/w halves, 32 banks; b64 read halves, 64 banks; b64 write 16-lane x4,
  32 banks; b128 read {0..3,12..15,20..27},{4..11,16..19,28..31},(+32), 64 banks; b128 write
  8-lane x8, 32 banks. -> cdna4_lds; suite 26 on gfx950: 32/32 equal the hardware counter.
- HW_ID on gfx950: xcc 0..7, se 0..3, 8 CUs per (xcc,se) (cu_id 0..8, one id absent per SE),
  256 distinct = rocminfo's 256 CUs / 32 SEs.
- Full suite on gfx950: 24 passed, 0 failed, 3 skipped = rocBLAS/hipBLASLt suites, N/A on gfx950
  (gfx90a-only instrumented libraries). Triton on gfx950 links dh_comms_dev_gfx950_co5.bc
  (arch from triple amdgpu9.50).
- dh_comms 0c8a363..9551a41 pushed to AMDResearch/dh_comms main. omniprobe main: 825928d,
  f38429e, 9666303 (tree identical to the validated mi350 branch).
- Not run on gfx90a: the final main (gfx950 model + dh_comms gfx950 + fault-test change). gfx90a
  evidence is 27/27 at 9fc83ea/mi350-21764ce, i.e. this code minus the measured cdna4_lds and the
  fault-test change; both only affect gfx950 or keep gfx90a's assertions (bare status 3).

# Handoff — iv_lds-bank-model

## Current Status (2026-11-09, end of the MI210 work)

- gfx950 and gfx90a are both measured and modelled (dh_comms `tools/lds_bank_probe`,
  branch `lds-bank-model` at ad8f231, pushed). Report `report-lds-2026-11-09.md` has both
  columns.
- Handler: per-instruction classes on gfx90a and gfx950 (cf8d8e8, pushed). gfx908/gfx942
  keep size-based classes with the gfx90a geometry.
- kerneldb fix pushed on kerneldb branch `lds-bank-model` (be0af40); omniprobe pointer
  bumped (ba8a245). origin/main f5a5721 merged into the branch.
- Validated on gfx90a: suite 26 78/78 (under the lock), full suite 28/28.

## Next

- Merged to main everywhere (2026-11-09, after gfx950 re-validation): omniprobe main 6aefd17,
  dh_comms main ad8f231, kerneldb main be0af40. The packet can be completed
  (`/workflow-complete`) once the supervisor agrees nothing is left.

## Previous status (2026-11-09, end of the MI350 session)

- gfx950 is done.
  - Every DS access class, including all atomics, is measured and modelled: dh_comms
    `tools/lds_bank_probe`, branch `lds-bank-model` at 237b0e3, pushed.
  - The handler uses kernelDB's DS instruction on gfx950. LDS atomics are instrumented.
  - Suite 26 has 74 kernels, all equal to the counter on gfx950.
  - Report for Rene: `report-lds-2026-11-09.md`. Its gfx90a column is TBD.
- **kerneldb fix not pushed:**
  - The fix is on branch `lds-bank-model` (be0af40) in this worktree's kerneldb submodule,
    which has no pushable remote here (origin is the main checkout's submodule path). The
    patch is `kerneldb-end-sequence.patch`.
  - The omniprobe submodule pointer is NOT bumped.
  - Without the fix, suite 26's `write_r2b64_stride8` fails (0 vs 120) on the current code
    layout.
  - The supervisor decides how kerneldb gets it.

## Done: MI210 steps (were "Next")


1. Build: `cmake -S . -B /tmp/oplds/build -DCMAKE_HIP_ARCHITECTURES=gfx90a ...` (memory
   `Omniprobe Build with Triton`). Apply the kerneldb patch if it is still not upstream:
   `git -C external/kerneldb checkout lds-bank-model`.
2. `external/dh_comms/tools/lds_bank_probe/run_all.sh /tmp/lds-90a`. The GFX90A entries in
   model.py are the old model (b96, read2, atomics and transposes unknown) and will show
   mismatches. Fit them from the data and copy the results to
   `.untracked/lds-meas/gfx90a-<date>/`.
3. Fill the gfx90a column of the report. Add gfx90a classes to `lds_model` and enable
   `lds_classes_from_isa` for gfx90a. Rerun suite 26 (under the lock) and the full suite
   (`/tmp/oplds/run_all_no26.sh` equivalent: run_all_tests.sh without suite 26, with
   BUILD_DIR and OMNIPROBE_ROOT set).
4. Check ikl's prediction: `i+(i>>4)` should also be 2-way on gfx90a.

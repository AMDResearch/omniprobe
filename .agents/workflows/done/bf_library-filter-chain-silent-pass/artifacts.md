# Artifacts

- Discovery log (8/11 run with the silent pass, 2026-10-27):
  `.untracked/pr44-suite-t380-2026-10-27.log` — later overwritten by the 11/11 rerun; the
  quoted warning lines are reproduced in `dossier.md` § Background.
- Pre-fix acceptance run: summarised in `handoff.md` § Current Status.
- To fill during execution: grep of other suites for the same hardcoded-`build/` pattern
  (Non-Goal to fix here, but list hits).

## Closing gate — 2026-11-08, gfx90a (MI210), ROCm 7.2.0

Before the fix (`da67b44`):
```
FAIL  AC-1     rc=0; Test 5 PASSED present: 0; skip/uninstrumented warnings: 2
FAIL  AC-2     INST_PLUGIN='<unset>', expected '/work1/amd/rvanoo/repos/omniprobe/build/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so'
FAIL  AC-3     rc=0; Test 2 PASSED present: 0; SKIP present: 0
FAIL  AC-4     Test 2 PASSED despite uninstrumented test libraries
FAIL  AC-6     counters 'passed skipped failed': incidental='0 1 0' (want 1 0 0), whole-skip='0 1 0' (want 0 1 0), failing='0 0 1' (want 0 0 1)
PASS  AC-7     real Triton suite with TRITON_DIR unset is still classified skipped
PASS  AC-5     full suite: 13 run, 13 passed, 0 skipped, 0 failed
PASS  SCOPE    no writes outside the declared write scope (2 entries; working tree and commits since 631e0866ff8acef5695f3bf7e756739ef61d2a4b)
```
After the fix (`2419835`):
```
PASS  AC-1     Tests 2-5 ran against OMNIPROBE_ROOT with no build/ in the repo root
PASS  AC-2     test libraries instrumented with the plugin from OMNIPROBE_ROOT
PASS  AC-3     missing omniprobe tree fails loudly (rc=1), no SKIP string
PASS  AC-4     with --no-instrument, Test 2 does not report PASSED (rc=0)
PASS  AC-6     classifier: incidental SKIP -> passed, whole-suite skip -> skipped, non-zero -> failed
PASS  AC-7     real Triton suite with TRITON_DIR unset is still classified skipped
PASS  AC-5     full suite: 13 run, 13 passed, 0 skipped, 0 failed
PASS  SCOPE    no writes outside the declared write scope (2 entries; working tree and commits since 631e0866ff8acef5695f3bf7e756739ef61d2a4b)
```

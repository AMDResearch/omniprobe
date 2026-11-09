# Handoff — iv_lds-bank-model

## Current Status

gfx950 measured and modelled (artifacts.md). Harness in dh_comms `tools/lds_bank_probe`
(branch lds-bank-model, b3e2e8f). Handler not changed yet (supervisor: after both arches).

Update (turn 2): handler uses kernelDB's DS instruction on gfx950 (87d9363); suite 26 has
58 kernels, all equal to the counter on gfx950. gfx90a still size-based.

Update (turn 3): atomics instrumented and modelled (gfx950); suite 26 71/71; report for
Rene in report-lds-2026-11-09.md (gfx90a column TBD).

## Next

1. On the MI210 node: `external/dh_comms/tools/lds_bank_probe/run_all.sh /tmp/lds-90a`;
   the gfx90a entries in model.py are the old model (b96 unknown) and will show mismatches
   where it is wrong; fix model.py from the data, copy results to .untracked/lds-meas/.
2. Handler (src/memory_analysis_handler.cc): add 12-byte classes, read2/write2 (needs the
   ISA instruction, not the IR size), sub-dword broadcast is already per dword; decide
   atomics (are LDS atomics instrumented at all?); the per-arch table from model.py.
   Extend suite 26 with kernels for the new classes; show it fails on the current code.

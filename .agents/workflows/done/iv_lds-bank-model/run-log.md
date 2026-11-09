# Run Log — iv_lds-bank-model

- 2026-11-09 oplds: worktree/branch set up; dh_comms branch lds-bank-model. ISA survey
  (subagent). Wrote tools/lds_bank_probe (lds_probe.cpp, probe.py, model.py, run_all.sh).
  gfx950 campaign: basic/pairs/delta/random for 43 ops; model matches 109122/109122
  aligned patterns. Incident: ds_add_u64 with misaligned addresses hung while holding
  /tmp/gpu-measure.lock (~10 min, delayed ikl); killed with kill <pid>; probe.py now
  wraps lds_probe in `timeout -s KILL` inside the lock, and run_all.sh keeps atomics
  aligned. dh_comms b3e2e8f pushed to origin/lds-bank-model.
- 2026-11-09 (turn 2): atomics spot-check (cmpst = 16 banks, float atomics lane-serial and
  invisible to the conflict counter); ikl blockmix predicted exactly; handler takes the
  DS class from kernelDB (87d9363); suite 26 extended to 58 kernels, 58/58 on gfx950,
  13 of the new fail on the old handler. dh_comms 243e27c.
- 2026-11-09 (turn 2, cont.): merged accesses on separate lines (6fe98df) and the flat
  exemption (this commit's parent chain). gfx950 build of the branch in /tmp/oplds/build:
  full suite 23 passed, 3 skipped (rocBLAS/hipBLASLt gfx90a-only), 0 failed, with suite 26
  run separately under the lock: 62/62. Library filter chain needs OMNIPROBE_ROOT set when
  BUILD_DIR is not <repo>/build (environment, not a regression).
- 2026-11-09 (turn 3): kernelDB lookup uses the original kernel's ISA [read
  interceptor.cc:1156/:983; meas: clones differ (no merging, dh_comms LDS traffic), originals
  in the instrumented binary identical to the plain build 61/62, the 62nd by one v_cndmask].
  LDS atomics instrumented (f69118b): plugin atomicrmw/cmpxchg on addrspace 3 as read_write;
  handler atomic classes, float atomics -> serialized_lanes, atomic-optimizer (v_mbcnt)
  -> one lane. Suite 26: 71/71 on gfx950; atomics fail on 3c4b771 (3 kernels). Full suite
  23 pass / 3 skip / 0 fail. Report for Rene: report-lds-2026-11-09.md.
- 2026-11-09 (turn 4): remaining gfx950 atomics measured (dh_comms 237b0e3): float min/max
  and f64 add/max follow the integer classes; only float add is lane-serial; mskor = cmpst_b32
  class; cmpst_b64 = 8 lanes / 16 banks. No hangs or faults (aligned only). Handler and suite 26
  extended (b32f9ba, 74 kernels). Found that kernelDB maps DWARF end_sequence rows (function
  starts attributed to the previous function's last line; write_r2b64_stride8 0 vs hw 120):
  fixed on local kerneldb branch lds-bank-model (be0af40, patch in packet); with it 74/74 and
  the full suite green (23 pass / 3 skip / 0 fail). Report updated.
- 2026-11-09 (MI210 node, gfx90a): kerneldb lds-bank-model (be0af40) pushed, pointer bumped
  (ba8a245); origin/main f5a5721 merged (conflicts: results.py and current-focus,
  both sides kept). run_all.sh campaign (every lds_probe run under the lock): 55 ops, 140257
  aligned patterns; gfx90a model fitted in model.py (dh_comms ad8f231), all match. Differs
  from gfx950 only in read_b64 (4x16 lanes, 128 B) and read_b128 (8-lane b96 groups, 128 B);
  add_f64 base 8 cycles. i+(i>>4) pad 2-way, i+(i>>5) conflict-free on gfx90a [meas].
  Handler: cdna_lds = measured gfx90a model, lds_classes_from_isa on for gfx90a (cf8d8e8).
  Suite 26 under the lock: 21/74 differ before, 78/78 equal after (+4 padding kernels).
  Full suite 27/27 (+ suite 26) with OMNIPROBE_ROOT=/tmp/oplds/build and hand-built
  rocBLAS/hipBLASLt drivers. Note: test-env.sh prepends the main checkout's build/ to
  LD_LIBRARY_PATH; the first full run used it and was discarded.
  Data: .untracked/lds-meas/gfx90a-2026-11-09/.
- 2026-11-09 (MI350 node, gfx950 re-validation of 6aefd17): clean build /tmp/oplds/build950;
  suite 26 under the exclusive lock 78/78 (hole16/hole32: 2/0, as on gfx90a); full suite
  under the shared lock without suites 20 (deliberate GPU fault) and 26: 23 pass, 3 skip
  (rocBLAS/hipBLASLt gfx90a-only), 0 fail. Merged (fast-forward): dh_comms main 9551a41..ad8f231,
  kerneldb main 5bec946..be0af40, omniprobe main f5a5721..6aefd17. Submodule pointers already
  equal the new submodule mains; no bump needed.

### 2026-11-09T09:49:09-06:00

- **Actor**: oplds worker
- **Planned step**: Workflow completion
- **Action taken**: All acceptance criteria verified. Workflow marked done.
- **Result**: success
- **Files touched**: dossier.md, handoff.md, active-workflows.md, current-focus.md
- **Verification**: no acceptance.sh (packet predates it); manual: AC-1/2 dh_comms b3e2e8f/237b0e3, AC-3 ad8f231 (140257 patterns, 0 mismatches), AC-4 suite 26 78/78 on gfx90a and gfx950 under the lock, fails 21/74 before on gfx90a; full suite green on both.
- **Criteria impact**: All criteria met
- **Blocker / Risk**: none

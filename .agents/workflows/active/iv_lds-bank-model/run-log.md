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

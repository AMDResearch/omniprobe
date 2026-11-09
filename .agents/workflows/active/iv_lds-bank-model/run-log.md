# Run Log — iv_lds-bank-model

- 2026-11-09 oplds: worktree/branch set up; dh_comms branch lds-bank-model. ISA survey
  (subagent). Wrote tools/lds_bank_probe (lds_probe.cpp, probe.py, model.py, run_all.sh).
  gfx950 campaign: basic/pairs/delta/random for 43 ops; model matches 109122/109122
  aligned patterns. Incident: ds_add_u64 with misaligned addresses hung while holding
  /tmp/gpu-measure.lock (~10 min, delayed ikl); killed with kill <pid>; probe.py now
  wraps lds_probe in `timeout -s KILL` inside the lock, and run_all.sh keeps atomics
  aligned. dh_comms b3e2e8f pushed to origin/lds-bank-model.

# Artifacts — bf_bb-interval-dynamic-alloca (2026-11-08, gfx90a, ROCm 7.2.0)

Suite 22 fixed 3/3, unfixed 3/3 FAIL (see dossier). Investigation scratch (node-local):
/tmp/opimpl-bbi (kernels, raw-dump handler, patched plugins, ISA before/after).

## What fix A does NOT give: meaningful per-block times (measured, not fixed here)

- With fix A every interval is ~4 `s_memtime` ticks: codegen moves the block's work past the stop
  clock (into the loop latch) and hoists loads above the start clock, so start and stop end up
  adjacent in the ISA.
- Prototype (not in the tree): `llvm.amdgcn.sched.barrier(0)` after the start and before the stop
  clock, plus an empty `asm sideeffect` use of each block live-out before the stop clock. Then the
  loop body reads 60 ticks steadily (10/1000/100000 iterations), and a straight-line FMA chain
  scales roughly linearly (K=16/256/1024/4096 → 4788/15696/57216/179524 ticks).
- Caveats: ~160x slowdown per loop iteration (each block inlines ~1000 instructions of submit
  code); `s_memtime` rate measured ~8.0e8 ticks/s vs ~1.28e9 from count/uptime, so no reliable
  conversion to time [inf: not fixed-rate]; resolution >= 4 ticks; intervals from other waves
  overlap, so a block time is a latency, not exclusive cost. Usable for relative comparison of
  heavy blocks/hot loops, labelled "ticks, instrumented"; not for absolute time.
- Line attribution uses the block's first instruction without following inlinedAt (entry block
  reported a HIP header line).
- Effort estimate (sub-investigation, inferred): pinning made robust incl. Triton variant 1-2 d;
  host-side per-block timing analyzer (aggregation, BBStart-consistent numbering and lines,
  JSON/CSV, analytics entry) 2-3 d; docs 0.5 d. Total ~1-1.5 weeks.
- Side observation, not investigated: `-a <nonexistent .so>` hung omniprobe until a 120 s timeout.

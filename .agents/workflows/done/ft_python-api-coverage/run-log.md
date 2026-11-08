# Run-Log

## Log Entries

### 2026-11-08 — created, implemented, verified (one session)

- Sampled every analyzer's JSON on gfx90a to design parsers. Confirmed: addresses = one per
  active lane, increasing lane order (dh_comms `active_lane_id`; measured 16 at the 1-in-4 store).
- C++ (`40a46b3`), launcher (`2f60d83`), API + tests (`b8105ee`), install (`5cbb8e2`), docs
  (`890389f`).
- First launcher rewrite relied on handlers returning what they read; test 6's custom handler
  returns nothing and the suite hung. Reworked: the loop reads lines and hands handlers a
  one-line stream. No stray processes left.
- Old launcher on a stub: stdout lines on stderr, blank line lost; new: preserved per stream.
- Two-file `-fgpu-rdc` + plugin: link error reproduced (follow-up packet). Two-file non-RDC:
  both kernels instrumented and attributed.
- Unit 18/18; suite 17 7/7 (base API 7/7 FAIL); full suite 17/17.

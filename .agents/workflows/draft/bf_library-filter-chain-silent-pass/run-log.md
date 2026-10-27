# Run-Log

Append an entry after every meaningful execution step.

## Log Entries

### 2026-10-27 — packet created

- **Actor**: claude
- **Planned step**: draft the packet; confirm the acceptance script reproduces the bug
- **Action taken**: wrote dossier, acceptance.sh, handoff; ran acceptance.sh against unfixed code
- **Result**: AC-1, AC-2, AC-3 FAIL (reproduction); AC-5, SCOPE PASS. AC-4 initially PASSED
  vacuously (Test 2 gated off by missing `build/`); check corrected with a `build/` symlink and
  re-run in isolation — now FAILs pre-fix, printing `NOT INSTRUMENTED (unexpected)` then
  `Test 2 PASSED`.
- **Files touched**: this packet only
- **Verification**: acceptance.sh run, gfx90a, Triton 3.8.0, HEAD b12d7f0
- **Criteria impact**: none met — reproduction established for AC-1..AC-4
- **Blocker / Risk**: none

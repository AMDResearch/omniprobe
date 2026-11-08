# Run-Log

## Log Entries

### 2026-11-08 — reproduced, fixed, verified

- Repro in /tmp (k.hip + other.hip): plugin rc 1 duplicate __hip_cuid_9d59...; no plugin rc 0.
- Fix; repro links, both kernels instrumented with accesses.
- Suite 13 tests: unfixed 3/3 FAIL, fixed 3/3 PASS. Full suite 17/17.
- Incident: a nested heredoc in my own shell command ran part of a test body as shell, creating 4 stray files in the home work dir (a HIP stub and 3 logs, mine, seconds old); removed exactly those. No repository effect.

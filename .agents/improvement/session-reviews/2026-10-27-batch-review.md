# Batch Session Review

**Date:** 2026-10-27
**Captures reviewed:** (all 12 captures newer than `2026-07-13-batch-review.md`, oldest first)
- `2026-07-14-0000-claude.md`
- `2026-07-20-1800-claude.md`
- `2026-07-27-1800-claude.md`
- `2026-07-28-0000-claude.md`
- `2026-07-29-0834-claude.md`
- `2026-09-08-0700-claude.md`
- `2026-09-08-0824-claude.md`
- `2026-09-08-1004-claude.md`
- `2026-09-08-1047-claude.md`
- `2026-10-26-0707-claude.md`
- `2026-10-27-0505-claude.md`
- `2026-10-27-1255-claude.md`

All 12 were read in full in one pass; no batching was needed.

## Top Friction Pattern

**Defective verification instruments: a check that passes, or would pass, without being able to
detect what it exists to detect.** This is the framework's **FM-7**, recurring at high rate. Roughly
17 instances across 5 of the 12 captures, every one in a session that wrote or ran checks:

- `09-08-0700`: three. AC-9 counted `Adding` lines, which the fix renamed, so the rename alone
  satisfied it. AC-8's new test passed against the broken build. `grep -c … || echo 0` yields
  `"0\n0"` at exactly the zero count it was meant to detect.
- `09-08-0824`: `tests/library_filter_chain/run_test.sh` proved an exclusion by asserting the
  *absence* of an `Adding` line, which could no longer fire after the rename. It was found only
  because a sibling presence check failed loudly.
- `09-08-1004`: seven gate checks, all written that session. Three passed vacuously (two greps
  matched the test's own text, one matched the run's own `LOGDUR_DISPATCHES=2` echo). Two failed
  falsely. Two more targeted an API or output string that does not exist.
- `10-27-0505`: AC-4 passed vacuously, an `exporting cache` grep used the wrong phrase, and a draft
  comment quoted the staleness pattern it would itself match. Separately,
  `library_filter_chain/run_test.sh` was found to have three paths that print
  `All tests passed` after skipping four of its five tests.

The local shape is clear. **Per-packet gates get the negative-control treatment and are fixed the
same day. Long-lived instruments get diagnosed, recorded as a risk or a draft, and stay in
service.** There are three such instruments, all still live at this review:

1. `library_filter_chain/run_test.sh`: silent-pass paths diagnosed and reproduced 2026-10-27.
   The fix is a draft packet, not yet queued for execution.
2. `tests/run_all_tests.sh:59`: classifies a whole suite as skipped if `SKIP` appears anywhere in
   its output. Recorded only as a Project-Level Risk in `current-focus.md`.
3. `session-close`'s outbound-content scan: inert because `scripts/leak-scan.sh` does not exist.
   It was raised on 09-08 (`0824`, `1047`), when the pattern matched 7 tracked files. **It matches
   10 now** (`git grep -l -E "$AMP_DEC6_PATTERN" | wc -l` → 10, all cluster hostnames, all
   pushed). The inert check let the count grow while every close looked clean.

This is FM-7's own sub-case: *"a finding recorded on a seed is scheduled work, not a fix. If a
defective instrument is left in service, its cost recurs at an undiminished rate."*

**Secondary pattern (framework FM-6 / FM-13):** environment-conditioned measurements were stored as
code facts. The Handler-tests failure and the "rocBLAS `sscal` not found" risk were gfx90a binaries
measured on gfx950 and carried for months as defects. They were retracted on 09-08. The mechanism
named in the retraction was itself corrected on 10-26 (the "exit 0" was `bf_exit-status-not-propagated`,
not the mismatch). Exit-status propagation (`c5aec00`) now makes the mismatch loud, which removes
most of the hazard.

**Process recurrence (framework FM-5):** the review nudge fired in 7 of these captures, and by the
end the wording was escalated and explicit about the cost. The backlog still reached 12 captures
over 106 days before this review ran.

## Positive Pattern

**Building the broken state and watching the check fail before trusting it passing.** This caught
every per-packet instrument defect listed above in-session, before any of them licensed a claim:
three on 09-08-0700, seven on 09-08-1004, AC-4 on 10-27-0505. On 10-27-1255 a sandbox reproduced
Triton's jq failure both with and without `set -e` before the upstream comment was posted. A
related habit: incoming seeds are verified claim by claim rather than trusted (`09-08-1004`).

## Action Taken

- [ ] Added to failure-modes.md as FM-L<n>: not done. The pattern is the framework's FM-7, and
      the local file defers to the framework's list for FM-4..FM-13 by design. A local duplicate
      would fork the definition.
- [x] Drafted local proposal: see `local-proposals/2026-10-27-retire-defective-long-lived-instruments.md`
- [ ] No action needed: not applicable. The pattern is known, but it is mitigated only for
      per-packet gates, not for long-lived instruments.

# Proposal: Retire the three known-defective long-lived instruments instead of recording them

**Origin:** session review 2026-10-27 (batch). FM-7 recurrence, long-lived-instrument sub-case.
**Problem:** Three diagnosed-defective checks remain in service and keep returning clean results:
`tests/library_filter_chain/run_test.sh` (silent pass), the `tests/run_all_tests.sh:59` `SKIP`
substring classifier, and the inert `session-close` leak scan (no `scripts/leak-scan.sh`, 7 → 10
matching tracked files since 2026-09-08).
**Proposed Change:**
1. `.agents/workflows/draft/bf_library-filter-chain-silent-pass/dossier.md`: add
   `tests/run_all_tests.sh` to the write scope and an AC that a suite is classified as skipped
   only by an explicit marker or exit code. Promote it ahead of `bf_intern-clone-name` in
   `current-focus.md`, still behind `bf_pyhandler-gil`.
2. Owner decision on the leak scan: either add `scripts/leak-scan.sh`, or make `session-close`
   report the step as `WEAK (inert)` in the capture rather than skipping it silently.
**Expected Benefit:** Suite tallies and clean closes become evidence again; the hostname count stops growing.
**Risk:** Item 1 widens a draft's scope (an amendment, not a contract change). Item 2 touches a framework skill, so it may belong upstream.

**Outcome (2026-10-27):** Item 1 was accepted and applied to the draft packet (AC-6/7, reordered
second). For item 2, `scripts/leak-scan.sh` was copied verbatim from the framework repo, and the
upstream gap was filed as rwvo/agentic_meta_project#5. The 4 cluster hostnames already in
10 tracked files and 2 pushed commit messages were reviewed by the owner the same day: accepted,
no history rewrite, no new ones (guardrail added). On 2026-11-08 (D1) the owner chose an
accepted-findings baseline for `scripts/leak-scan.sh` over scrubbing; see
`scripts/leak-scan-baseline.txt`.

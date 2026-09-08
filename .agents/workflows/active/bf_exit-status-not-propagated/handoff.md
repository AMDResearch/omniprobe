# Handoff

**Location**: `.agents/workflows/active/bf_exit-status-not-propagated/handoff.md`

## Current Status

**Active**, promoted 2026-09-08 after passing `workflow-readiness-check`. Base commit `821c89b`.
Filed the same day from an incoming seed. No production code changed.

The readiness check repaired two defective checks in this packet's `acceptance.sh` before
promotion. No acceptance criterion changed. If you edit those checks, read the dossier's
Verification Strategy notes first — each is indirect on purpose and the obvious simplification
reintroduces the defect it was written to avoid.

**This packet will be executed in a fresh session by an agent with none of the filing context**,
so the dossier is written to stand alone. Read it rather than the seed; the seed is preserved at
`.agents/workflows/seeds/bf_exit-status-not-propagated.md` but the dossier supersedes it and
records the verification.

## Last Verified

2026-09-08, at `8de44b0`, by reading the source. Every claim in the seed was re-checked in this
repository and all held:

- `omniprobe/omniprobe:169` — the comment `# Get process return code` is immediately followed by
  `remaining = process.stdout.read()`. The status is never read.
- `omniprobe/omniprobe:823` — `main()` discards the call's result, then finalizes JSON at `:825`,
  then falls off the end.
- `omniprobe/api/omniprobe.py:154` — the sole failure check is `if result.returncode != 0`.
  `:164` returns `"[]"` when the output file is missing.
- A second caller exists at `:225` (`rocminfo`, for ISA detection) and constrains the fix.

The end-to-end measurement (exit 0 on a SIGSEGV target) was made by the filing agent on gfx950 at
`44547f9` and is **not** re-measured here — Plan Of Record step 1 does that first.

## Step 0 — re-stamp the base commit before anything else

Three packets were promoted together on 2026-09-08, and the promotion commit touched all three
packet directories. A packet's own directory is allowlisted by `ac_check_write_scope`; its
**siblings' are not**. So every one of the three currently reports the other two's files as
out-of-scope writes:

    FAIL  SCOPE  writes outside declared scope: .agents/workflows/active/<another-packet>/...

That is the check working correctly on the wrong subject. Nothing is actually out of scope, and
chasing it by re-stamping all three in turn is circular — whichever is stamped last puts the
others back in range.

**First action on picking this packet up:** set `- Base Commit:` in `dossier.md` to
`git rev-parse HEAD`, commit that one-line change on its own, and re-run `acceptance.sh`. `SCOPE`
returns to `PASS` and stays there, because from then on the only commits in range are this
packet's own.

## Next Exact Step

Plan Of Record step 1: reproduce. On any node, no GPU needed:

    build/bin/omniprobe -i -a MemoryAnalysis -- /bin/sh -c 'kill -SEGV $$'; echo "got: $?"

Expect `0`; the defect is that it is not `139`. Then the same with `exit 42`.

Then step 2 — make the three decisions in the dossier's Background and **write them into
`run-log.md` before implementing**, because each is observable behaviour and a later reader
cannot tell a decision from an accident.

## Active Risks / Blockers

- **Open Question 1 is unmeasured and could bite at step 3.** If the Triton path drives a target
  that has always exited nonzero harmlessly, propagating the status turns a silent pass into a
  loud failure there. Check before implementing. The failure policy says report it, not
  special-case it back to silence.
- **`tests/run_all_tests.sh` is shared with two other active packets.** Append only your own
  `run_suite` line; do not reformat or reorder. See the dossier's § Dependencies.
- The `SKIP` substring anywhere in the new test's output marks the whole suite skipped
  (`tests/run_all_tests.sh:59`) and would make AC-8 misreport.

## Required Reads Before Resuming

1. This file, then `dossier.md`.
2. `.agents/pm/units/omniprobe-cli.md` — PM unit for the script being changed.
3. The seed only if you want the filing agent's downstream framing; the dossier carries the facts.

## Proposed Spec Changes

None.

## Scope Amendments

None.

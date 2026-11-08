# Dossier — bf_logger-record-interleave

## Metadata

- Workflow ID: bf_logger-record-interleave
- Workflow Type: bugfix
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Base Commit: 7f826d1

```write-scope
src/message_logger.cc
tests/test_two_file_app.sh
tests/two_file_app/
tests/run_all_tests.sh
```

## Objective

AddressLogger/BasicBlockLogger `-t json` output is one valid JSON object per line, also when
dispatches overlap.

## Background

Found while re-checking ikimpl's s4 scenario: 48642 of 524000 lines invalid, shape `{A}{B}` +
empty line. One dh_comms processing thread per dispatch; each logger has its own stream on the
same file; libstdc++ writes ≥1 KiB strings directly, separately from the following newline
(inference from the observed shape and libstdc++'s xsputn behaviour; not traced in its source).
Fix: one process-wide mutex around each record's write + flush.

## Acceptance Criteria

- **AC-1**: suite 18 test 3: all 523936 trace lines valid; unfixed 84114 invalid (3 earlier
  probe runs: 68992, 79310, 73400).
- **AC-2**: full suite 18/18.

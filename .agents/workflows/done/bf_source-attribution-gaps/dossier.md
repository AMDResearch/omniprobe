# Dossier — bf_source-attribution-gaps

## Metadata

- Workflow ID: bf_source-attribution-gaps
- Workflow Type: bugfix
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Base Commit: 7f826d1

```write-scope
inc/kdb_message_handler_base.h
inc/memory_analysis_handler.h
src/memory_analysis_handler.cc
omniprobe/api/
docs/usage.md
tests/test_two_file_app.sh
tests/two_file_app/
tests/run_all_tests.sh
```

## Objective

Every MemoryAnalysis entry names its source file, and accesses MemoryAnalysis cannot attribute
are counted and reported instead of silently dropped.

## Background

Supervisor asked to re-check ikimpl's empty `source_file` in its s4_makefile scenario (two files,
non-RDC; copied read-only to /tmp). Found on 7f826d1:
1. with -g: one load (merged into a wider ISA load, no instruction at its column) recorded with
   `source_file: ""` (`get_dwarf_info` returns no name when no exact file/line/column match);
2. the shared resolver (`kdb_message_handler_base::sourceFileForHash`) resolved nothing in this
   build: basic-block instruction copies have no path ids; the line map has them;
3. without -g (the scenario Makefile's flags): every message dropped (`access_size == 0xffff`
   path), report empty, no word.

## Acceptance Criteria

- **AC-1**: suite 18 test 1 (with -g, every entry in its own file); unfixed FAIL.
- **AC-2**: suite 18 test 2 (without -g: `unattributed_accesses` > 0 per kernel, stderr hint);
  unfixed FAIL.
- **AC-3**: ikimpl's scenario: all 5 stencil loads named `stencil.hip`; without -g counts reported.
- **AC-4**: full suite 18/18; API unit tests 18/18.

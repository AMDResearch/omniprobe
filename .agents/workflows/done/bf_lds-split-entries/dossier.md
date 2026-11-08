# Dossier — bf_lds-split-entries

## Metadata

- Workflow ID: bf_lds-split-entries
- Workflow Type: bugfix
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Base Commit: 8a3ea17b51b3a9a7f3b3b0f2dd22d85c8b27dc2c

```write-scope
src/memory_analysis_handler.cc
tests/test_json_output.sh
tests/test_kernels/CMakeLists.txt
tests/test_kernels/lds_split_test.cpp
```

## Objective

MemoryAnalysis reports exactly one entry per (source location, space, access type), each with a
source file.

## Background

ikimpl 4c (`/tmp/ikimpl/calib/kf.json`): LDS entries split 4095 + 65 and 63 + 1; the small
halves have `source_file: "<unknown source file>"`. Cause (`memory_analysis_handler.cc`, bank-
conflict path): the LDS file name came only from `fname_hash_to_fname`, filled by global
accesses (kernelDB has no ds_* info). Fix: fall back to `kdb_message_handler_base::sourceFileForHash`.

## Acceptance Criteria

- **AC-1**: suite 12 `memory_analysis_one_entry_per_location` passes; unfixed: FAIL (2 splits).
- **AC-2**: ikimpl's kernel: 0 splits (3 runs); unfixed 16 splits on 5/5 runs.
- **AC-3**: full suite 17/17.

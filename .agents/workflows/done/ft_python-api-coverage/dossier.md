# Dossier — ft_python-api-coverage

## Metadata

- Workflow ID: ft_python-api-coverage
- Workflow Type: feature
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Base Commit: 5d9266b
- Requested by: IntelliKit worker (ikimpl), via the supervisor, 2026-11-08

```write-scope
omniprobe/api/
omniprobe/omniprobe
inc/kdb_message_handler_base.h
inc/basic_block_analysis.h
src/basic_block_analysis.cc
inc/message_logger.h
src/message_logger.cc
src/memory_heatmap.cc
inc/memory_analysis_handler.h
src/memory_analysis_handler.cc
CMakeLists.txt
docs/usage.md
docs/hip-instrumentation.md
tests/test_python_api.py
tests/test_python_api_e2e.sh
tests/test_exit_status.sh
tests/test_kernels/CMakeLists.txt
tests/run_all_tests.sh
```

## Objective

IntelliKit can drive every Omniprobe analyzer through the Python API with typed results that
match its spec, and can tell when a result is partial.

## Scope (from ikimpl's request; supervisor's fold-in list)

1. `analyze_heatmap`, `log_addresses`, `log_basic_blocks` (+ result classes), streaming parse with
   `max_records` / `truncated`.
2. AddressLogger JSON: `source_file`, `memory_space`, `access_size`; BBStart records:
   `basic_block_id` (confirmed = `user_data`).
3. `MemoryAccess`: `cache_lines_needed`, `cache_lines_used`, `isa_instruction`, `ir_bytes`, `isa_bytes`.
4. `uninstrumented_kernels` on every result.
5. Flat accesses: counted and reported (JSON `unanalyzed_flat_accesses`, stderr line, API field).
   Runtime classification of flat addresses is out of scope (see Follow-ups).
6. Launcher stdout/stderr: fixed (separate streams), documented for handler authors.
7. Docs: `-fgpu-rdc` is optional; API reference.
8. Python API installed into the install tree; exe fallback next to the package.

## Where the spec and the analyzers' truth differ (reported to ikimpl)

- `AddressRecord.source_file/line/column` is the instruction's own debug location; for code
  inlined from a header (e.g. `blockDim`, a 2-byte `constant` read at `amd_hip_runtime.h:264`)
  it is the header. Not changed: MemoryAnalysis matches on exactly that location.
- `HeatmapPage.end_address` is inclusive (start + page_size − 1).
- `BBRecord` has no timing semantics beyond the raw `timestamp` (the BBA rework removed derived
  timing; the timestamp is taken at submit, so deltas include instrumentation overhead).
- Heatmap JSON had no `page_size`; added.

## Acceptance Criteria

- **AC-1**: unit tests (`tests/test_python_api.py`, 18) pass; the 8 new ones cover the new
  parsers, `max_records` truncation, `uninstrumented_kernels`, extended fields, exe fallback.
- **AC-2**: suite 17 (`test_python_api_e2e.sh`) passes 7/7 on real binaries; against the base
  API all 7 fail (missing methods/fields).
- **AC-3**: exit-status suite test 7 (streams) passes; fails on the base launcher.
- **AC-4**: `cmake --install` puts `omniprobe/api` in the prefix; `env -i` interpreter with
  `<prefix>` on the path imports it and finds `<prefix>/omniprobe/bin/omniprobe`.
- **AC-5**: full suite 17/17 on gfx90a.

## Follow-ups (not in this packet)

- `bf_plugin-dhcomms-cuid-duplicate`: `-fgpu-rdc` + plugin + ≥2 source files fails to link with
  `duplicate symbol: __hip_cuid_9d59523df4651ffa` — reproduced on 5d9266b; the dh_comms device
  bitcode carries its own `__hip_cuid_` global and the plugin links it into every TU. Next.
- Zero-parameter kernels not matched at runtime (ikimpl 4b); split LDS entries (4c).
- Runtime classification of flat addresses (M–L): needs the aperture bases at run time.
- Empty `source_file` in a two-file non-RDC build (ikimpl s4_makefile): a simple two-file
  non-RDC build attributes both files correctly on 5d9266b+; re-check their scenario.

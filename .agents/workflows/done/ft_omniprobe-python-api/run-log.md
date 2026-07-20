# Run-Log

Append an entry after every meaningful execution step. This is not optional. If the session is interrupted, this log is the only record of progress.

## Entry Format

Use append-only entries with:

- timestamp
- actor
- planned step
- action taken
- result
- files touched
- verification run
- criteria impact
- blocker or risk

## Log Entries

### 2026-07-20 12:30

- **Actor**: claude (intellikit-sidecar session)
- **Planned step**: Create workflow packet
- **Action taken**: Created draft packet from refined meta-brief. All design decisions resolved with user: subprocess wrapper model, all analyses in scope, Python API in Omniprobe repo.
- **Result**: success — packet created at `.agents/workflows/draft/ft_omniprobe-python-api/`
- **Files touched**: dossier.md, run-log.md, handoff.md, artifacts.md
- **Verification**: N/A (packet creation)
- **Criteria impact**: None yet
- **Blocker / Risk**: Potential overlap with `rf_rename-logduration-to-omniprobe` (broad scope refactor). Coordinate execution order.

### 2026-07-20 13:00

- **Actor**: claude (intellikit-sidecar session)
- **Planned step**: Run readiness check and promote to active
- **Action taken**: Ran workflow-readiness-check (11/11 pass). Moved packet from draft/ to active/. Updated dossier lifecycle state, handoff, and active-workflows.md.
- **Result**: success — workflow promoted to active
- **Files touched**: dossier.md, handoff.md, active-workflows.md
- **Verification**: Readiness check passed all 11 structural items
- **Criteria impact**: None yet
- **Blocker / Risk**: Potential overlap with rf_rename-logduration-to-omniprobe remains

### 2026-07-20 18:00

- **Actor**: claude (omniprobe session)
- **Planned step**: Resume workflow, begin PoR step 1 (audit current JSON output)
- **Action taken**: Loaded dossier, handoff, PM units (architecture, memory-analysis, handler-pipeline). Read handler source files (memory_analysis_handler.cc, basic_block_analysis.cc, headers) and CLI script. Completed code audit of existing JSON output capabilities.
- **Result**: Audit complete. Findings documented below.
- **Files touched**: run-log.md (this entry)
- **Verification**: Code read only — no changes yet
- **Criteria impact**: Informs AC-1, AC-2 implementation
- **Blocker / Risk**: None
- **Execution mode**: autonomous. Checkpointing per guardrails § Checkpoint Protocol.

### 2026-07-20 18:30

- **Actor**: claude (omniprobe session)
- **Planned step**: PoR Steps 2-3 — implement JSON output for both handlers
- **Action taken**: Restructured MemoryAnalysis report_json() to emit flat per-access objects with kernel/dispatch_id at top level and explicit excess_cache_lines/bank_conflicts fields. Added json_escape(). Created BasicBlockAnalysis report_json() with per-block objects including basic_block_id, source_file, line, percentile timing (p25-p99), min/max cycles, wave_count. Added duration_samples_ collection in handle(). Separated JSON/CSV code paths. Built clean, ran all tests.
- **Result**: success — commit f2cf90f
- **Files touched**: src/memory_analysis_handler.cc, src/basic_block_analysis.cc, inc/basic_block_analysis.h
- **Verification**: Build clean (0 warnings). 35/35 tests pass (handler: 25/25, library filter: 5/5, triton: 5/5). 3 suites skipped (rocBLAS, hipBLASLt, combined — instrumented libs not present).
- **Criteria impact**: AC-1 (MemoryAnalysis JSON) — implemented. AC-2 (BasicBlockAnalysis JSON) — implemented. AC-5 (backward compat) — verified (all tests pass).
- **Blocker / Risk**: None

### 2026-07-20 19:00

- **Actor**: claude (omniprobe session)
- **Planned step**: PoR Steps 5-8 — Create Python API, result dataclasses, error handling, tests
- **Action taken**: Created `omniprobe/api/` module with `__init__.py`, `omniprobe.py` (Omniprobe class with `analyze_memory()` and `analyze_basic_blocks()`), `results.py` (6 dataclasses). Implemented error handling for missing binary, non-zero exit, malformed JSON. Created `tests/test_python_api.py` with 10 unit tests covering parsing, error cases, and dataclass construction. Re-ran full C++ test suite to confirm no regressions.
- **Result**: success — commit 0cb19df. All acceptance criteria implemented.
- **Files touched**: omniprobe/api/__init__.py (new), omniprobe/api/omniprobe.py (new), omniprobe/api/results.py (new), tests/test_python_api.py (new)
- **Verification**: 10/10 Python API unit tests pass. 35/35 C++ tests pass (3 suites skipped for env). Build clean.
- **Criteria impact**: AC-3 (Python API module) — implemented. AC-4 (result dataclasses) — implemented. AC-6 (error handling) — implemented. AC-7 (tests) — implemented.
- **Blocker / Risk**: None

### Acceptance Criteria Status

| AC | Status | Evidence |
|----|--------|----------|
| AC-1 | Met | MemoryAnalysis emits flat JSON with `kernel`, `dispatch_id`, `source_file`, `line`, `column`, `excess_cache_lines`, `bank_conflicts` per access |
| AC-2 | Met | BasicBlockAnalysis emits JSON with `kernel`, `dispatch_id`, per-block objects with `basic_block_id`, `source_file`, `line`, `min_cycles`, `max_cycles`, `p25`, `p50`, `p75`, `p95`, `p99`, `wave_count` |
| AC-3 | Met | `omniprobe/api/` importable, `Omniprobe` class with `analyze_memory()` and `analyze_basic_blocks()` |
| AC-4 | Met | `MemoryAnalysisResult`, `BasicBlockResult`, `KernelMemoryResult`, `KernelBBResult`, `MemoryAccess`, `BasicBlock` dataclasses with all required fields |
| AC-5 | Met | 35/35 existing tests pass — no regressions |
| AC-6 | Met | `FileNotFoundError`, `RuntimeError`, `ValueError` raised per spec; tested |
| AC-7 | Met | 10 unit tests covering both handlers' JSON parsing and error cases |

### 2026-07-20 19:30

- **Actor**: claude (omniprobe session)
- **Planned step**: Document new features in user docs, agent docs, and CLI help
- **Action taken**: Updated 7 files: `docs/usage.md` (JSON schema reference, Python API section with example/reference/error table), `README.md` (Python API section, project structure), `omniprobe/omniprobe` (-t help text expanded with schema descriptions and API reference), `.agents/pm/units/memory-analysis.md` (JSON schema), `.agents/pm/units/omniprobe-cli.md` (Python API files, JSON schema section, corrected flag names), `.agents/pm/pm-current-state.md` (active work areas, changed assumptions), `.agents/pm/pm-index.md` (updated CLI unit scope).
- **Result**: success — commit 798d3bf
- **Files touched**: docs/usage.md, README.md, omniprobe/omniprobe, .agents/pm/units/memory-analysis.md, .agents/pm/units/omniprobe-cli.md, .agents/pm/pm-current-state.md, .agents/pm/pm-index.md
- **Verification**: `omniprobe -h` shows expanded -t help. All tests pass.
- **Criteria impact**: Documentation gap closed. All ACs remain met.
- **Blocker / Risk**: None

**Audit findings — PoR Step 1:**

**MemoryAnalysis (`memory_analysis_handler.cc`):**
- JSON output exists via `report_json()` (line 759), triggered when `LOGDUR_LOG_FORMAT=json`.
- Output structure: `{ "kernel_analysis": { "kernel_info": {...}, "cache_analysis": { "accesses": [...] }, "bank_conflicts": { "accesses": [...] } }, "metadata": {...} }`
- Cache analysis fields: `source_location.file`, `.line`, `.column`, `code_context`, `access_info.type`, `.execution_count`, `.ir_bytes`, `.isa_bytes`, `.isa_instruction`, `.cache_lines.needed`, `.cache_lines.used`
- Bank conflict fields: `source_location.file`, `.line`, `.column`, `code_context`, `access_info.type`, `.execution_count`, `.ir_bytes`, `.total_conflicts`
- **Gap vs AC-1**: AC-1 expects flat per-kernel arrays with fields `kernel`, `dispatch_id`, `source_file`, `line`, `column`, `excess_cache_lines`, `bank_conflicts`. Current JSON uses a nested structure. The AC fields are present but named/structured differently. The current JSON is actually richer than what AC-1 requires.
- **JSON validity issue**: Multi-dispatch JSON uses manual `[` / `,` management between dispatches; `finalize_json_output()` in Python CLI appends closing `]`. Console output omits array brackets. Single-object case handled with wrap-in-array in Python. This is fragile but functional.

**BasicBlockAnalysis (`basic_block_analysis.cc`):**
- JSON output: when `LOGDUR_LOG_FORMAT != "csv"`, `report()` calls `renderJSON()` to emit per-block JSON objects.
- Output is a sequence of separate JSON objects (one per basic block), NOT wrapped in an array. Each object has: `kernel`, `dispatch_id`, `kernel_branchiness`, `block_start_line`, `block_end_line`, `block_duration`, `kernel_file_name`, `block_branchiness`, `block_overhead`, `block_count`, `instructions: {...}`.
- `renderComputeResources()` also emits a JSON line with compute resource mapping.
- **Gap vs AC-2**: AC-2 expects per-kernel arrays with `basic_block_id`, `source_file`, `line`, `min_cycles`, `max_cycles`, `p25`, `p50`, `p75`, `p95`, `p99`, `wave_count`. Current JSON is missing `basic_block_id`, percentile fields, and `wave_count`. Has `block_duration`, `block_count`, `block_branchiness` instead. Output is also not valid JSON (multiple objects without array wrapper).
- **Significant rework needed** for BasicBlockAnalysis JSON to meet AC-2.

**CLI (`omniprobe/omniprobe`):**
- `-t json` flag sets `LOGDUR_LOG_FORMAT=json` env var. Both handlers read this env var.
- `-l` sets `LOGDUR_LOG_LOCATION` for file output.
- `finalize_json_output()` handles MemoryAnalysis array closing bracket.
- No equivalent JSON finalization for BasicBlockAnalysis.

### 2026-07-20 20:00

- **Actor**: claude (omniprobe session)
- **Planned step**: Workflow completion
- **Action taken**: All acceptance criteria verified. Workflow marked done. Dossier lifecycle set to done. Packet moved to done/. active-workflows.md archived. current-focus.md pruned.
- **Result**: success
- **Files touched**: dossier.md, handoff.md, active-workflows.md, current-focus.md
- **Verification**: AC-1 through AC-7 all met with evidence (see Acceptance Criteria Status table above). 35/35 C++ tests pass, 10/10 Python API tests pass, build clean, docs updated.
- **Criteria impact**: All criteria met
- **Blocker / Risk**: none

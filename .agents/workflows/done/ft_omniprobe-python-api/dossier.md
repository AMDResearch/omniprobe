# Dossier

## Metadata

- Workflow ID: ft_omniprobe-python-api
- Workflow Type: feature
- Lifecycle State: done
- Owner / Current Executor: unassigned
- Intended Write Scope: `omniprobe/api/` (new), `src/memory_analysis_handler.cc`, `src/basic_block_analysis.cc`, `plugins/`, `omniprobe/omniprobe` (CLI script), `tests/`
- Dependencies On Other Active Workflows: Potential overlap with `rf_rename-logduration-to-omniprobe` (broad scope). If the rename refactor lands first, file paths in this workflow's write scope will change. Coordinate accordingly.

## Objective

Add a Python API module and structured JSON output to Omniprobe so it can be consumed programmatically by IntelliKit and other tools.

## Background / Context

IntelliKit is a monorepo of agent-first Python tools for AMD GPU performance analysis. All IntelliKit tools follow a pattern: Python API class -> MCP server -> CLI -> agent skill. To integrate Omniprobe as an IntelliKit tool, Omniprobe needs:

1. Reliable, well-defined JSON output from all analysis handlers.
2. A Python API module that drives the CLI and parses JSON results into structured objects.

Currently, MemoryAnalysis outputs unstructured text to console (JSON/CSV support may be partial). BasicBlockAnalysis output format needs verification. The Python orchestrator script (`omniprobe/omniprobe`) handles CLI argument parsing and subprocess execution but exposes no importable API.

This workflow is the Omniprobe-side prerequisite for IntelliKit integration (tracked as `ft_omniprobe-tool` in the IntelliKit sidecar).

## Contract

The agent may change implementation approach without approval. The agent may not weaken, redefine, or substitute acceptance criteria without approval.

## Acceptance Criteria

- **AC-1**: MemoryAnalysis handler produces valid JSON when invoked with `-t json`. JSON includes per-kernel arrays with fields: `kernel`, `dispatch_id`, `source_file`, `line`, `column`, `excess_cache_lines`, `bank_conflicts`.
- **AC-2**: BasicBlockAnalysis handler produces valid JSON when invoked with `-t json`. JSON includes per-kernel arrays with fields: `kernel`, `dispatch_id`, `basic_block_id`, `source_file`, `line`, `min_cycles`, `max_cycles`, `p25`, `p50`, `p75`, `p95`, `p99`, `wave_count`.
- **AC-3**: A new `omniprobe/api/` Python module exists and is importable. It contains:
  - `class Omniprobe` with constructor accepting `omniprobe_path: Optional[str] = None` (defaults to PATH lookup).
  - `analyze_memory(command: str, kernel_filter: Optional[str] = None, dispatches: str = "all") -> MemoryAnalysisResult`
  - `analyze_basic_blocks(command: str, kernel_filter: Optional[str] = None, dispatches: str = "all") -> BasicBlockResult`
- **AC-4**: Result dataclasses are defined:
  - `MemoryAnalysisResult` with `.kernels: list[KernelMemoryResult]`, each containing `.kernel_name`, `.dispatch_id`, `.accesses: list[MemoryAccess]` (with `.source_file`, `.line`, `.column`, `.excess_cache_lines`, `.bank_conflicts`).
  - `BasicBlockResult` with `.kernels: list[KernelBBResult]`, each containing `.kernel_name`, `.dispatch_id`, `.basic_blocks: list[BasicBlock]` (with `.bb_id`, `.source_file`, `.line`, `.min_cycles`, `.max_cycles`, `.p50`, `.p75`, `.p95`, `.p99`, `.wave_count`).
- **AC-5**: Existing CLI behavior is unchanged — default text output, `-t csv` output, and all existing flags work as before.
- **AC-6**: The Python API handles error cases gracefully: omniprobe binary not found raises `FileNotFoundError`; non-zero exit code raises `RuntimeError` with stderr; malformed JSON raises `ValueError`.
- **AC-7**: At least one test exists for each handler's JSON output (can use existing test kernels in `tests/test_kernels/`).

## Failure Policy

Stop and report if:
- JSON output cannot be reliably structured for either handler due to C++ handler architecture limitations.
- The CLI interface requires breaking changes to support JSON (violating AC-5).
- The `rf_rename-logduration-to-omniprobe` refactor has landed and file paths have shifted — re-baseline write scope before proceeding.

## Scope

- C++ handler source: `src/memory_analysis_handler.cc`, `src/basic_block_analysis.cc`
- Handler plugins: `plugins/memory_analysis_plugin.cc`, `plugins/basic_block_plugin.cc`
- CLI script: `omniprobe/omniprobe`
- New Python API: `omniprobe/api/__init__.py`, `omniprobe/api/omniprobe.py`, `omniprobe/api/results.py`
- Tests: `tests/` (new API tests)
- Headers: `inc/memory_analysis_handler.h`, `inc/basic_block_analysis.h` (if JSON output requires interface changes)

## Non-Goals

- Making Omniprobe pip-installable or changing the CMake build system.
- Changing the C++ plugin architecture or handler factory interface.
- Adding new analysis types beyond MemoryAnalysis and BasicBlockAnalysis.
- Modifying dh_comms or kerneldb submodules.
- Triton-specific changes (the API should work with both ROCm and Triton instrumented kernels transparently).

## Constraints and Assumptions

- All work on a separate git branch (not directly on main). Branch will be merged after review.
- Must work with the existing CMake build — no build system changes.
- JSON output must preserve source file/line/column attribution from DWARF info.
- The Python API locates the omniprobe installation via PATH or an explicit path argument.
- Python 3.10+ (matching IntelliKit's minimum).
- The `omniprobe/api/` module should have minimal dependencies (standard library + dataclasses only; no pip dependencies beyond what omniprobe already requires).
- The JSON schema should be stable enough for IntelliKit to depend on — document it in docstrings or a schema dict.

## Dependencies

- Omniprobe must be built with test kernels available (standard `cmake --build` workflow).
- ROCm 7.0+ and GPU access required for integration testing of JSON output.
- If `rf_rename-logduration-to-omniprobe` lands first, file paths will change. This workflow should either complete before that refactor or re-baseline afterward.

## Plan Of Record

1. **Audit current JSON output.** Run existing test kernels with `-t json` for both MemoryAnalysis and BasicBlockAnalysis. Document what currently works and what gaps exist.
2. **Implement MemoryAnalysis JSON output.** Modify `memory_analysis_handler.cc` to emit structured JSON (array of objects) when the JSON log format is active. Ensure source attribution (file, line, column) is included.
3. **Implement BasicBlockAnalysis JSON output.** Modify `basic_block_analysis.cc` similarly. Include percentile breakdown fields.
4. **Verify JSON output.** Run test kernels, validate JSON is parseable, check all expected fields are present.
5. **Create Python API module.** Create `omniprobe/api/` with the `Omniprobe` class that shells out to the CLI with `-t json` and parses results.
6. **Define result dataclasses.** Create `MemoryAnalysisResult`, `BasicBlockResult`, and supporting types.
7. **Add error handling.** Handle missing binary, non-zero exit, malformed JSON.
8. **Write tests.** API-level tests using real test kernels (integration) and mock-based unit tests for JSON parsing.
9. **Validate backward compatibility.** Run existing tests to confirm no regressions.

## Verification Strategy

- **AC-1, AC-2**: Run test kernels with `-t json -l output.json`, parse output with Python `json.load()`, assert all required fields present.
- **AC-3, AC-4**: Import `omniprobe.api` in Python, call methods, check return types.
- **AC-5**: Run existing test suite (`tests/run_*.sh`), confirm no regressions.
- **AC-6**: Unit tests with mocked subprocess: test FileNotFoundError, RuntimeError, ValueError.
- **AC-7**: Integration test using `simple_memory_analysis_test` and a BB test kernel.

## References

- IntelliKit sidecar workflow: `ft_omniprobe-tool` (depends on this workflow)
- Seed file: `.untracked/omniprobe_as_tool.md` (IntelliKit sidecar)
- IntelliKit tool patterns: `metrix/src/metrix/api.py`, `kerncap/kerncap/__init__.py` (reference implementations)
- Omniprobe PM units: `architecture.md`, `memory-analysis.md`, `handler-pipeline.md`

## Open Questions

None — all design decisions resolved during refinement.

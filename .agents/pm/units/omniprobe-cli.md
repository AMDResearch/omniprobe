# Omniprobe CLI

## Responsibility

Python script that orchestrates running instrumented applications. Sets up environment variables, invokes the target application, and handles output finalization.

## Key Source Files

| File | Purpose |
|------|---------|
| `omniprobe/omniprobe` | Main Python orchestrator script |
| `omniprobe/config/analytics.py` | Analyzer configuration (handler + plugin mapping) |
| `omniprobe/config/triton_config.py` | Triton-specific configuration |
| `omniprobe/api/__init__.py` | Python API public exports |
| `omniprobe/api/omniprobe.py` | `Omniprobe` class — programmatic API for running analyses |
| `omniprobe/api/results.py` | Result dataclasses (`MemoryAnalysisResult`, `BasicBlockResult`, etc.) |

## Key Types and Classes

- **`Omniprobe`** (`omniprobe/api/omniprobe.py`) — Drives the CLI with `-t json` and parses output. Methods: `analyze_memory()`, `analyze_basic_blocks()`.
- **Result dataclasses** (`omniprobe/api/results.py`):
  - `MemoryAnalysisResult` → `KernelMemoryResult` → `MemoryAccess`
  - `BasicBlockResult` → `KernelBBResult` → `BasicBlock`

## Key Functions and Entry Points

N/A — script-level orchestration.

## Data Flow

1. Parse command line arguments
2. Build environment variable dict based on flags
3. Execute target application with modified environment
4. Finalize output (e.g., close JSON array)

### Key Options

| Flag | Purpose |
|------|---------|
| `-i` | Enable instrumented kernel dispatch |
| `-a handler` | Select analysis handler |
| `-l path` | Output location (file path or "console") |
| `-t format` | Output format (csv, json); JSON produces structured schemas |
| `-c cache` | Triton cache location (triggers Triton mode) |
| `--filter-x/y/z` | Filter messages by block index |
| `--library-filter FILE` | JSON config for library include/exclude filtering |
| `--instrumentation-scope SCOPE` | Limit instrumentation to source file/lines (Triton only) |

### Available Analyzers

| Analyzer | Description | Message Handler | Triton Plugin |
|----------|-------------|-----------------|---------------|
| AddressLogger | Log raw memory traces | libLogMessages64.so | libAMDGCNSubmitAddressMessages-triton.so (default) |
| BasicBlockLogger | Log raw timestamps from basic blocks | libLogMessages64.so | libAMDGCNSubmitBBStart-triton.so |
| Heatmap | Produce per-dispatch memory heatmap | libdefaultMessageHandlers64.so | libAMDGCNSubmitAddressMessages-triton.so (default) |
| MemoryAnalysis | Analyze memory access efficiency | libMemAnalysis64.so | libAMDGCNSubmitAddressMessages-triton.so (default) |
| BasicBlockAnalysis | Analyze basic block execution | libBasicBlocks64.so | libAMDGCNSubmitBBStart-triton.so |

### HIP vs Triton Workflow

- **HIP mode:** The user must pre-compile kernels with `-fpass-plugin=<plugin>` to create instrumented variants. At runtime, omniprobe sets `LD_PRELOAD` to load the interceptor, which swaps to the `_inst` variant at dispatch time.
- **Triton mode:** Activated by passing `-c <cache>`. Omniprobe sets `LLVM_PASS_PLUGIN_PATH` so Triton's JIT compiler loads the instrumentation plugin automatically during compilation. No manual pre-compilation step is required.

### Library Filter Config Format

The `--library-filter FILE` flag accepts a JSON file that controls which HIP libraries are intercepted. The file specifies include and/or exclude lists of library paths. Only dispatches from matching libraries will be instrumented.

## JSON Output Schemas

When `-t json` is specified, handlers emit structured JSON suitable for machine parsing.

- **MemoryAnalysis**: per-dispatch object with `kernel`, `dispatch_id`, flat `accesses` array. Each access has `source_file`, `line`, `column`, `excess_cache_lines`, `bank_conflicts`, `memory_space`, `access_type`.
- **BasicBlockAnalysis**: per-dispatch object with `kernel`, `dispatch_id`, `basic_blocks` array. Each block has `basic_block_id`, `source_file`, `line`, timing percentiles (`p25`–`p99`), `min_cycles`, `max_cycles`, `wave_count`.

The Python API (`omniprobe/api/`) wraps this: `Omniprobe.analyze_memory()` and `Omniprobe.analyze_basic_blocks()` return dataclasses that parse these schemas.

## Invariants

- Must be run from installation directory (paths resolved relative to script)
- Target application passed after `--` separator
- JSON output auto-finalized (closing bracket added)
- Only one LLVM plugin can be loaded at a time
- HIP requires pre-instrumentation; Triton instruments during JIT compilation

## Dependencies

- **Interceptor** — loaded via `LD_PRELOAD`. Also load: `interceptor.md`
- **Handler Pipeline** — handler loading at runtime. Also load: `handler-pipeline.md`

## Negative Knowledge

- `libAMDGCNSubmitBBInterval-triton.so` exists but no analyzer currently uses it. Do not wire it up without a corresponding analyzer.
- Requires `pyfiglet` for ASCII banner display. This is a runtime dependency of the script.

## Open Questions

None.

## Last Verified

- 2026-07-20 (updated for Python API, JSON schema docs, corrected flag names)

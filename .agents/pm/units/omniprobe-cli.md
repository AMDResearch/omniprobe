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
  *(Extended 2026-11-08, `b8105ee`, `5cbb8e2`:)* methods are `analyze_memory`,
  `analyze_basic_blocks`, `analyze_heatmap`, `log_addresses`, `log_basic_blocks` (the two
  loggers stream, with `max_records` / `truncated`). Every result has `uninstrumented_kernels`.
  Installed to `<prefix>/omniprobe/api`; `Omniprobe()` falls back to the sibling launcher.
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
  **Superseded 2026-11-08:** timing fields were removed; blocks now report `wave_visits` and
  `active_lanes`, keyed by the BBStart IR block ordinal. See `handler-pipeline` § BasicBlockAnalysis semantics.
- **Heatmap / AddressLogger / BasicBlockLogger**: JSON Lines, not an array. Output-file
  truncation, stream routing (reports → stdout, interceptor → stderr) and the same-second
  `results_<timestamp>.json` collision are recorded in `handler-pipeline` § Output files.

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

- `libAMDGCNSubmitBBInterval-*.so` has no analyzer, by decision (BBInterval is experimental; see `instrumentation`). Do not wire it up as a timing analyzer.
- Requires `pyfiglet` for ASCII banner display. This is a runtime dependency of the script.

## The CLI propagates the target's exit status (fixed 2026-09-08, verified 2026-10-26)

**This section previously recorded the opposite** — that `omniprobe` always exits 0 — which was
true until `c5aec00`. `bf_exit-status-not-propagated` is complete (packet in
`.agents/workflows/done/`, GitHub issue #41 closed). Current behaviour:

- `capture_subprocess_output` returns `process.returncode` instead of discarding it, and
  **returns rather than exiting** on failure. That constraint was load-bearing: the function has
  a second caller (`rocminfo`, ISA detection) that must survive a non-zero status.
- `main()` exits with the target's status.
- Signal deaths surface as `128 + signo` via a named `shell_exit_status()` helper. A `SIGSEGV`
  target reports **139**, a target exiting 42 reports **42**, success still reports **0**.
- `omniprobe/api/omniprobe.py` raises `RuntimeError` on a crashing target rather than quietly
  returning `"[]"`.
- JSON output is finalized **before** the exit, so a failing run still leaves a parseable file.
  `finalize_json_output` writes `[]` when file output was requested and nothing was produced —
  without that, a no-GPU target produced no file at all and the ordering was unobservable.

Covered by `tests/test_exit_status.sh`, registered as **suite 11** in `run_all_tests.sh`. It
needs no GPU — every target is a `/bin/sh` stub — so it runs on any node.

### Why this matters beyond the CLI

The constant `0` was not merely hiding crashes; it was being **misread as evidence about the
hardware**. `current-focus.md` recorded that a gfx90a binary on a gfx950 GPU "fails to dispatch
silently, producing exit 0 with no output". It does nothing of the kind — it dies of `SIGSEGV`
and exits 139. The silence was this bug, observed through the CLI, and two phantom "known
defects" were attributed to that misreading before it was caught. Both have been retracted.

## Launcher configuration checks and ROCm resolution (2026-11-08, `149cf2c`)

- **Configuration errors exit 1 before the target runs**: an unknown analyzer name (was
  "Ignoring." and ran the defaults), a nonexistent `.so` path given to `-a`, and for
  `-a PythonHandler` an unset `OMNIPROBE_PYTHON_HANDLER` or a missing `.py` file. Deeper module
  problems are caught by the plugin's `omniprobeValidateHandlers` (see `handler-pipeline`).
- **ROCm for kernelDB:** `get_rocm_path()` takes the first candidate that has
  `llvm/bin/llvm-objdump`, in order: `ROCM_PATH`; the ROCm the core library links against
  (`ldd liblogDuration64.so` → `libhsa-runtime64.so`); `hipconfig --rocmpath`; the install
  prefix of `hipconfig`/`rocminfo`/`hipcc` on `PATH`; `/opt/rocm-*` (newest first);
  `/opt/rocm`. It **exports `ROCM_PATH` to the child** (kernelDB reads it once at load, default
  `/opt/rocm`, which this cluster lacks) and errors for `-i` if nothing is found. Without this,
  dispatches were silently dropped (see `interceptor` § Failure handling).
- **Child output is forwarded in raw chunks as written** (`os.read`, 64 KiB), stdout and stderr
  kept separate. Line-by-line alternation between the two streams used to splice a stdout line
  into the middle of the interceptor's stderr exit summary.
- `-k` is a regex searched in the demangled name (see `interceptor`); anchoring with `^` misses
  template kernels, whose demangled names begin with the return type (`void ...`).

## `-d random` (2026-11-08, `8e18d9e`)

Each dispatch the `-k` filter lets through is captured independently with probability 1/100
(`RANDOM_DISPATCH_DISTRIBUTION`, `src/utils.cc` `randomDispatcher`); the filter is applied first
(`interceptor.cc`, `filter_allows && canDispatch`). It is **not** "one random dispatch per kernel"
(the old docs). Kernels with few dispatches are usually not captured; the end-of-run summary now
lists every kernel random captured nothing of. Supervisor ruling (option A): keep the sampling;
changing it is on Rene's deferred list. Suite 27.

## Open Questions

None.

## Last Verified

- 2026-07-20 (updated for Python API, JSON schema docs, corrected flag names)
2026-09-08 (exit-status propagation; verified by reading and by running the CLI)
2026-10-26 (exit-status propagation complete and verified on gfx90a; prior "always exits 0" section rewritten)
2026-11-08 (Python API surface and BBA schema change from this session's commits; exit-status section not re-verified, resting on 2026-10-26)
2026-11-08 (second session: configuration-error checks, ROCm resolution order and ROCM_PATH export, raw-chunk output forwarding; verified by reading omniprobe/omniprobe at 22c4d95 and bf_robustness-errors; exit-status section not re-read)
- 2026-11-08 (third session): -d random section.

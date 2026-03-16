# omniprobe CLI

## Responsibility
Python script that orchestrates running instrumented applications. Sets up environment variables, invokes the target application, and handles output finalization.

## Core Concepts
- **Environment Setup**: Configures HSA_TOOLS_LIB, LOGDUR_*, LLVM_PASS_PLUGIN_PATH
- **Handler Selection**: `-a` flag selects analysis type (e.g., MemoryAnalysis)
- **Output Location**: `-o` flag specifies output file or "console"
- **Instrumented Mode**: `-i` flag enables dispatching instrumented kernels
- **HIP vs Triton**: For HIP, users compile with plugin manually; for Triton, omniprobe sets LLVM_PASS_PLUGIN_PATH for JIT compilation

## Key Invariants
- Must be run from installation directory (paths resolved relative to script)
- Target application passed after `--` separator
- JSON output auto-finalized (closing bracket added)

## Data Flow
1. Parse command line arguments
2. Build environment variable dict based on flags
3. Execute target application with modified environment
4. Finalize output (e.g., close JSON array)

## Interfaces
- CLI: `omniprobe [options] -- <target_app> [app_args]`

## Key Options

| Flag | Purpose |
|------|---------|
| `-i` | Enable instrumented kernel dispatch |
| `-a <handler>` | Select analysis handler (see Available Analyzers below) |
| `-o <path>` | Output location (file path or "console") |
| `-f <format>` | Output format (csv, json) |
| `-c <cache>` | Triton cache location (triggers Triton mode, sets LLVM_PASS_PLUGIN_PATH) |
| `--filter-x/y/z` | Filter messages by block index (N or N:M range) |
| `--library-filter FILE` | JSON config for library include/exclude filtering |
| `--instrumentation-scope SCOPE` | Limit instrumentation to source file/lines (Triton only, requires `-i` and `-c`) |
| `--instrumentation-scope-file FILE` | Read scope definitions from file (Triton only, requires `-i` and `-c`) |

### Library Filter Config Format
```json
{
  "include": ["/path/to/lib.so"],           // Add specific files to scan
  "include_with_deps": ["/path/to/*.so"],   // Add files + ELF dependencies
  "exclude": ["**/libm.so*", "/opt/ohpc/**"] // Remove from scanning (wins)
}
```
- Patterns support `*` (any except `/`) and `**` (any including `/`)
- `exclude` always wins (applied last)
- `include_with_deps` resolves DT_NEEDED entries recursively

## Available Analyzers

Configured in `omniprobe/config/analytics.py`:

| Analyzer | Description | Message Handler | Triton Plugin |
|----------|-------------|-----------------|---------------|
| **AddressLogger** | Log raw memory traces | `libLogMessages64.so` | `libAMDGCNSubmitAddressMessages-triton.so` (default) |
| **BasicBlockLogger** | Log raw timestamps from basic blocks | `libLogMessages64.so` | `libAMDGCNSubmitBBStart-triton.so` |
| **Heatmap** | Produce per-dispatch memory heatmap | `libdefaultMessageHandlers64.so` | `libAMDGCNSubmitAddressMessages-triton.so` (default) |
| **MemoryAnalysis** | Analyze memory access efficiency | `libMemAnalysis64.so` | `libAMDGCNSubmitAddressMessages-triton.so` (default) |
| **BasicBlockAnalysis** | Analyze basic block execution | `libBasicBlocks64.so` | `libAMDGCNSubmitBBStart-triton.so` |

**Plugin Selection Logic**:
- Default: `libAMDGCNSubmitAddressMessages-triton.so` (for memory address instrumentation)
- Override: Analyzers with `llvm_plugin` field in analytics.py override the default
- HIP mode: Users must compile with `-fpass-plugin=<plugin>` manually
- Triton mode: Omniprobe sets `LLVM_PASS_PLUGIN_PATH` when `-c <cache>` is provided

## Dependencies
- liblogDuration64.so (loaded via HSA_TOOLS_LIB)
- Handler plugins (loaded via LOGDUR_HANDLERS)
- Instrumentation plugins (loaded via LLVM_PASS_PLUGIN_PATH)

## Configuration
- `omniprobe/config/` — configuration files
- `runtime_config.txt` — generated at build time

## HIP vs Triton Instrumentation

### HIP Workflow
1. User compiles HIP code with `-fpass-plugin=/path/to/libAMDGCNSubmit*-rocm.so`
2. Executable contains both original and instrumented kernels
3. Omniprobe sets `HSA_TOOLS_LIB` and `LOGDUR_INSTRUMENTED=1` to enable dispatch interception
4. liblogDuration64.so swaps to instrumented kernels at runtime

### Triton Workflow
1. User runs omniprobe with `-c $HOME/.triton/cache` to trigger Triton mode
2. Omniprobe sets `LLVM_PASS_PLUGIN_PATH` based on selected analyzer
3. Triton JIT compiler loads plugin during kernel compilation
4. Rest of workflow same as HIP (dispatch interception, message handling)

**Key Difference**: HIP requires pre-instrumentation; Triton instruments during JIT compilation.

## Known Limitations
- Requires pyfiglet for ASCII banner
- Only one LLVM plugin can be loaded at a time (last analyzer wins if multiple specified)
- `libAMDGCNSubmitBBInterval-triton.so` exists but no analyzer currently uses it

## Last Verified
Date: 2026-03-16

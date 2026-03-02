# omniprobe CLI

## Responsibility
Python script that orchestrates running instrumented applications. Sets up environment variables, invokes the target application, and handles output finalization.

## Core Concepts
- **Environment Setup**: Configures HSA_TOOLS_LIB, LOGDUR_*, LLVM_PASS_PLUGIN_PATH
- **Handler Selection**: `-a` flag selects analysis type (e.g., MemoryAnalysis)
- **Output Location**: `-o` flag specifies output file or "console"
- **Instrumented Mode**: `-i` flag enables dispatching instrumented kernels

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
| `-a <handler>` | Select analysis handler (MemoryAnalysis, etc.) |
| `-o <path>` | Output location (file path or "console") |
| `-f <format>` | Output format (csv, json) |

## Dependencies
- liblogDuration64.so (loaded via HSA_TOOLS_LIB)
- Handler plugins (loaded via LOGDUR_HANDLERS)
- Instrumentation plugins (loaded via LLVM_PASS_PLUGIN_PATH)

## Configuration
- `omniprobe/config/` — configuration files
- `runtime_config.txt` — generated at build time

## Known Limitations
- Requires pyfiglet for ASCII banner
- Triton support via separate config

## Last Verified
Date: 2026-03-02

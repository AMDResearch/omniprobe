# Omniprobe Architecture

## Overview
Omniprobe is a toolkit for instrumenting HIP/Triton GPU kernels to extract runtime information such as memory access patterns, cache line usage, and LDS bank conflicts.

**Recent Changes** (2026-03-03):
- Merged agents branch into main (22 commits across 4 repos)
- Removed passthrough wrapper classes for cleaner architecture
- Added end-to-end test infrastructure via `tests/run_handler_tests.sh`
- Created test kernels with `CHECK_HIP` macro for clean error handling
- Improved test code readability (replaced binary constants with enums)
- Consolidated L2 cache line size definitions into `gpu_arch_constants.h`
- Cleaned up instrument-amdgpu-kernels submodule: removed 5 unused plugins, simplified to 3 dh_comms-based plugins (commits 5a5d7e0, 8869a43)

## System Diagram

```
                           ┌─────────────────────────────┐
                           │  omniprobe (Python script)  │
                           │  Sets env vars, launches    │
                           │  instrumented application   │
                           └──────────────┬──────────────┘
                                          │
                           ┌──────────────▼──────────────┐
                           │  liblogDuration64.so        │
                           │  (HSA tools library)        │
                           │  - Intercepts HSA dispatch  │
                           │  - Swaps instrumented knls  │
                           │  - Manages dh_comms + hdlrs │
                           └──────────────┬──────────────┘
                                          │
       ┌──────────────────┬───────────────┼───────────────┬──────────────────┐
       │                  │               │               │                  │
       ▼                  ▼               ▼               ▼                  ▼
┌─────────────┐    ┌─────────────┐ ┌─────────────┐ ┌─────────────┐   ┌─────────────┐
│ dh_comms    │    │ kerneldb    │ │ Message     │ │ comms_mgr   │   │ Plugins     │
│ (submodule) │    │ (submodule) │ │ Handlers    │ │ Pool mgmt   │   │ Handler     │
│ Dev↔Host IO │    │ ISA + DWARF │ │ Analysis    │ │             │   │ factories   │
└─────────────┘    └─────────────┘ └─────────────┘ └─────────────┘   └─────────────┘

       ┌───────────────────────────────────────────────────────────────────────┐
       │  instrument-amdgpu-kernels (submodule)                                │
       │  LLVM IR passes that clone kernels and insert instrumentation calls   │
       └───────────────────────────────────────────────────────────────────────┘
```

## Data Flow

1. **Build time**: LLVM plugins clone kernels, insert `v_submit_message()` calls
2. **Runtime**: `omniprobe` script sets `HSA_TOOLS_LIB=liblogDuration64.so`
3. **Dispatch**: `hsaInterceptor` intercepts dispatch, swaps to instrumented kernel
4. **Kernel exec**: Instrumented kernel streams messages to shared buffer
5. **Host thread**: `dh_comms` polls buffer, invokes message handlers
6. **Report**: After kernel completion, handlers report findings by source location

## Key Invariants

- Original kernels are preserved; instrumentation creates clones
- Instrumented kernels require extra `void*` arg pointing to `dh_comms_descriptor`
- Message handlers run on separate host threads, not blocking dispatch
- kerneldb correlates IR-level DWARF info with ISA-level instructions

## Subsystems (Top-Level)

| Subsystem | Location | Description |
|-----------|----------|-------------|
| Interceptor | `src/interceptor.cc` | HSA API hooking, dispatch interception |
| comms_mgr | `src/comms_mgr.cc` | Pool management for dh_comms objects |
| Memory Analysis | `src/memory_analysis_handler.cc` | Uncoalesced access + bank conflict detection |
| Plugins | `plugins/` | Message handler factory interface |
| omniprobe CLI | `omniprobe/omniprobe` | Python orchestrator script |
| Testing | `tests/` | End-to-end test infrastructure via omniprobe |

## Sub-projects (Git Submodules)

| Sub-project | Location | Description | KT Location |
|-------------|----------|-------------|-------------|
| dh_comms | `external/dh_comms/` | Device-host message passing | `external/dh_comms/.agents/kt/` |
| kerneldb | `external/kerneldb/` | ISA extraction, DWARF parsing | `external/kerneldb/.agents/kt/` |
| instrument-amdgpu-kernels | `external/instrument-amdgpu-kernels/` | LLVM IR instrumentation plugins | `external/instrument-amdgpu-kernels/.agents/kt/` |

## Build

- CMake-based, requires ROCm (hipcc, HSA headers)
- Sub-projects built via `ext_proj_add()` macro
- Produces: `liblogDuration64.so`, message handler plugins, `omniprobe` script
- Tests: `cmake -DINTERCEPTOR_BUILD_TESTING=ON`, run via `tests/run_handler_tests.sh`

### Build Configuration
Current build config stored in `build/CMakeCache.txt`. Key variables:
- `ROCM_PATH` — ROCm installation (default `/opt/rocm`)
- `CMAKE_HIP_ARCHITECTURES` — target GPU architectures (e.g., gfx90a)
- `TRITON_LLVM` — if set, builds Triton-compatible instrumentation plugins
- `CMAKE_INSTALL_PREFIX` — installation destination

Useful build artifacts:
- `build/compile_commands.json` — for IDE/LSP code navigation
- `build/runtime_config.txt` — generated config for omniprobe script

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `HSA_TOOLS_LIB` | Points to liblogDuration64.so |
| `LOGDUR_HANDLERS` | Comma-separated list of handler .so files |
| `LOGDUR_INSTRUMENTED` | Enable instrumented kernel dispatch |
| `LLVM_PASS_PLUGIN_PATH` | Path to instrumentation plugin |
| `LOGDUR_LOG_FORMAT` | Output format (csv, json) |

## Last Verified
Commit: 8869a43 (main repo), 5a5d7e0 (instrument-amdgpu-kernels submodule)
Date: 2026-03-03

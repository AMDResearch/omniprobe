# Architecture

## Responsibility

Omniprobe is a toolkit for instrumenting HIP/Triton GPU kernels to extract
runtime information such as memory access patterns, cache line usage, and LDS
bank conflicts.

## Key Source Files

| File | Purpose |
|------|---------|
| `src/interceptor.cc` | HSA API hooking, dispatch interception |
| `src/comms_mgr.cc` | Pool management for dh_comms objects |
| `src/memory_analysis_handler.cc` | Uncoalesced access + bank conflict detection |
| `plugins/` | Message handler factory interface |
| `src/instrumentation/` | LLVM IR instrumentation plugins |
| `omniprobe/omniprobe` | Python orchestrator script |
| `tests/` | End-to-end test infrastructure |

## Data Flow

1. **Build time:** LLVM plugins clone kernels, insert `v_submit_message()` calls.
2. **Runtime:** `omniprobe` script sets `LD_PRELOAD=liblogDuration64.so` (rocprofiler-sdk discovers tool).
3. **Dispatch:** `hsaInterceptor` intercepts dispatch, swaps to instrumented kernel.
4. **Kernel exec:** Instrumented kernel streams messages to shared buffer.
5. **Host thread:** `dh_comms` polls buffer, invokes message handlers.
6. **Report:** After kernel completion, handlers report findings by source location.

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
                           │  (rocprofiler-sdk tool)     │
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
       │  Instrumentation (src/instrumentation/)                               │
       │  LLVM IR passes that clone kernels and insert instrumentation calls   │
       └───────────────────────────────────────────────────────────────────────┘
```

## Subsystems

| Subsystem | PM Unit | Location | Purpose |
|-----------|---------|----------|---------|
| Interceptor | `interceptor.md` | `src/interceptor.cc`, `inc/interceptor.h` | HSA dispatch interception and kernel swapping |
| Handler Pipeline | `handler-pipeline.md` | `src/comms_mgr.cc`, `inc/comms_mgr.h`, `plugins/` | Handler loading, dh_comms pool management |
| Memory Analysis | `memory-analysis.md` | `src/memory_analysis_handler.cc` | Uncoalesced access and bank conflict detection |
| Instrumentation | `instrumentation.md` | `src/instrumentation/` | LLVM IR passes for kernel cloning and instrumentation |
| CLI Orchestrator | `omniprobe-cli.md` | `omniprobe/omniprobe` | Python entry point, environment setup |

## Sub-projects

| Sub-project | Location | Purpose |
|-------------|----------|---------|
| dh_comms | `external/dh_comms/` (submodule) | Device-to-host communication buffers and message types |
| kerneldb | `external/kerneldb/` (submodule) | ISA extraction, DWARF correlation, code object scanning |

## Build and Environment

See `build-system` PM unit for CMake configuration, environment variables, build/install
tree layout, and multi-LLVM-variant build details.

## Invariants

- Original kernels are preserved; instrumentation creates clones.
- Instrumented kernels require an extra `void*` arg pointing to `dh_comms_descriptor`.
- Message handlers run on separate host threads, not blocking dispatch.
- `kerneldb` correlates IR-level DWARF info with ISA-level instructions.

## Dependencies

- `interceptor.md` — HSA dispatch interception
- `handler-pipeline.md` — handler loading and dh_comms pool management
- `memory-analysis.md` — memory access analysis handler
- Sub-projects: dh_comms (device-host IO), kerneldb (ISA + DWARF correlation)

## Negative Knowledge

- **instrument-amdgpu-kernels was absorbed** into `src/instrumentation/` (2026-03-24). It is no longer a submodule. Do not look for or attempt to restore it as a submodule.
- **Standalone ROCm/hipBLASLt and ROCm/rocBLAS repos are deprecated.** Source now lives in the `ROCm/rocm-libraries` monorepo.

## Open Questions

None.

## Last Verified

2026-04-27 (trimmed by pm-restructure; build/env/path sections moved to build-system)

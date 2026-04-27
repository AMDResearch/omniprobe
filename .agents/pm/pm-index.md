# Project Memory Index

Project memory units record durable, reusable project knowledge. Load only the units relevant to the current task.

| Unit | Purpose | Status | Facet | When To Load | Dependencies |
|------|---------|--------|-------|--------------|--------------|
| `architecture` | Top-level architecture overview, system diagram, subsystems, data flow, environment variables, path layout | active | code | Starting any session; orienting on the project | None |
| `interceptor` | HSA API hooking via rocprofiler-sdk, dispatch interception, kernel swapping, library filtering | active | code | Working on src/interceptor.cc or dispatch logic | comms-mgr, sub-dh-comms, sub-kerneldb, plugins |
| `comms-mgr` | dh_comms object pool management, checkout/checkin semantics | active | code | Working on src/comms_mgr.cc or buffer pooling | interceptor, sub-dh-comms, plugins |
| `memory-analysis` | Memory access analysis handler — uncoalesced access detection, LDS bank conflict detection | active | code | Working on src/memory_analysis_handler.cc | sub-dh-comms, sub-kerneldb |
| `omniprobe-cli` | Python orchestrator script — CLI options, analyzer config, HIP/Triton workflow | active | code | Working on omniprobe/omniprobe or config/ | interceptor, plugins |
| `plugins` | Handler plugin factory interface — dlopen-based handler loading, built-in plugins | active | code | Working on plugins/ or adding new handlers | sub-dh-comms |
| `instrumentation` | LLVM IR instrumentation passes — kernel cloning, address/BB instrumentation, scope filtering | active | code | Working on src/instrumentation/ or CMake build for plugins | sub-dh-comms |
| `sub-dh-comms` | Device-host communication library (submodule) — shared buffers, message handler base class | active | code | Working on dh_comms integration or message format | None |
| `sub-kerneldb` | Kernel database (submodule) — ISA extraction, DWARF correlation, lazy loading API | active | code | Working on kerneldb integration or ISA analysis | None |
| `testing` | Test infrastructure — end-to-end test suites, test kernels, GoogleTest (disabled) | active | code | Working on tests/ or verifying changes | None |

## Usage Notes

- Keep PM selective. Do not turn it into a transcript dump.
- Split units when they stop being task-oriented.
- Move completed historical units into `.agents/pm/done/` when appropriate.
- See `pm-glossary.md` for GPU, HSA, LLVM, and Omniprobe-specific terminology.

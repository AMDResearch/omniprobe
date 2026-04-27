# Project Memory Index

Project memory units record durable, reusable project knowledge. Load only the units relevant to the current task.

| Unit | Purpose | Status | Facet | When To Load | Dependencies |
|------|---------|--------|-------|--------------|--------------|
| `architecture` | Top-level architecture overview, system diagram, subsystems, data flow | active | code | Starting any session; orienting on the project | build-system |
| `build-system` | CMake build configuration, install tree layout, multi-LLVM-variant builds, environment variables | active | code | Working on CMakeLists.txt, cmake_modules/, build config, or environment setup | architecture, instrumentation, testing |
| `interceptor` | HSA API hooking via rocprofiler-sdk, dispatch interception, kernel swapping, library filtering | active | code | Working on src/interceptor.cc or dispatch logic | handler-pipeline, sub-dh-comms, sub-kerneldb |
| `handler-pipeline` | Handler plugin loading (dlopen factory), dh_comms pool management (checkout/checkin), dispatch attachment | active | code | Working on plugins/, src/comms_mgr.cc, or handler loading | interceptor, sub-dh-comms |
| `memory-analysis` | Memory access analysis handler — uncoalesced access detection, LDS bank conflict detection | active | code | Working on src/memory_analysis_handler.cc | sub-dh-comms, sub-kerneldb |
| `omniprobe-cli` | Python orchestrator script — CLI options, analyzer config, HIP/Triton workflow | active | code | Working on omniprobe/omniprobe or config/ | interceptor, handler-pipeline |
| `instrumentation` | LLVM IR instrumentation passes — kernel cloning, address/BB instrumentation, scope filtering | active | code | Working on src/instrumentation/ | sub-dh-comms, build-system |
| `sub-dh-comms` | Device-host communication library (submodule) — shared buffers, message handler base class | active | code | Working on dh_comms integration or message format | None |
| `sub-kerneldb` | Kernel database (submodule) — ISA extraction, DWARF correlation, lazy loading API | active | code | Working on kerneldb integration or ISA analysis | None |
| `testing` | Test infrastructure — end-to-end test suites, test kernels, GoogleTest (disabled) | active | code | Working on tests/ or verifying changes | build-system |

## Usage Notes

- Keep PM selective. Do not turn it into a transcript dump.
- Split units when they stop being task-oriented.
- Move completed historical units into `.agents/pm/done/` when appropriate.
- See `pm-glossary.md` for GPU, HSA, LLVM, and Omniprobe-specific terminology.

# Project Memory Index

Project memory units record durable, reusable project knowledge. Load only the units relevant to the current task.

| Unit | Type | Purpose | Status | Facet | Always-Load | When To Load | Dependencies |
|----|----|-------|------|-----|-----------|------------|------------|
| `architecture` | arch-overview | Top-level architecture overview, system diagram, subsystems, data flow | active | code | false | Starting any session; orienting on the project | build-system |
| `build-system` | code-nav | CMake build configuration, install tree layout, multi-LLVM-variant builds, environment variables | active | code | false | Working on CMakeLists.txt, cmake_modules/, build config, or environment setup | architecture, instrumentation, testing |
| `interceptor` | code-nav | HSA API hooking via rocprofiler-sdk, dispatch interception, kernel swapping, library filtering | active | code | false | Working on src/interceptor.cc or dispatch logic | handler-pipeline, sub-dh-comms, sub-kerneldb |
| `handler-pipeline` | code-nav | Handler plugin loading (dlopen factory), dh_comms pool management (checkout/checkin), dispatch attachment | active | code | false | Working on plugins/, src/comms_mgr.cc, or handler loading | interceptor, sub-dh-comms |
| `memory-analysis` | code-nav | Memory access analysis handler — uncoalesced access detection, LDS bank conflict detection | active | code | false | Working on src/memory_analysis_handler.cc | sub-dh-comms, sub-kerneldb |
| `omniprobe-cli` | code-nav | Python orchestrator script — CLI options, analyzer config, HIP/Triton workflow, Python API (`omniprobe/api/`) | active | code | false | Working on omniprobe/omniprobe, config/, or omniprobe/api/ | interceptor, handler-pipeline |
| `instrumentation` | code-nav | LLVM IR instrumentation passes — kernel cloning, address/BB instrumentation, scope filtering | active | code | false | Working on src/instrumentation/ | sub-dh-comms, build-system |
| `sub-dh-comms` | code-nav | Device-host communication library (submodule) — shared buffers, message handler base class | active | code | false | Working on dh_comms integration or message format | None |
| `sub-kerneldb` | code-nav | Kernel database (submodule) — ISA extraction, DWARF correlation, lazy loading API | active | code | false | Working on kerneldb integration or ISA analysis | None |
| `testing` | infra | Test infrastructure — end-to-end test suites, test kernels, GoogleTest (disabled) | active | code | false | Working on tests/ or verifying changes | build-system |

## Usage Notes

- Keep PM selective. Do not turn it into a transcript dump.
- Split units when they stop being task-oriented.
- Move completed historical units into `.agents/pm/done/` when appropriate.
- See `pm-glossary.md` for GPU, HSA, LLVM, and Omniprobe-specific terminology.

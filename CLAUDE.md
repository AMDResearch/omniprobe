# Omniprobe - Claude Code Instructions

## Project Overview
Omniprobe is a toolkit for instrumenting HIP/Triton GPU kernels to extract runtime information.
See `.agents/kt/architecture.md` for detailed structure (once initialized).

## Knowledge Tree
This project uses a knowledge tree in `.agents/kt/` for structured project understanding.

**Quick reference**: `.agents/kt_usage.md`
**Full specifications**: `.agents/kt_workflows.md`

**Session workflow**:
- **Start**: `kt-load` — rehydrate context from KT
- **During**: Just code. Use `kt-reflect` if KT feels too coarse or too detailed.
- **End**: `kt-update` — persist learnings to KT
- **Refactoring**: Use `kt-refactor start|suspend|resume|finish|list` for multi-session refactors

If the knowledge tree doesn't exist yet, run `kt-init` first.
Use `kt-validate` to check for stale dossiers after skipping updates.

## Sub-projects
Three git submodules in `external/`, each may have their own `.agents/kt/`:
- `external/dh_comms` — device-host communication library
- `external/kerneldb` — kernel database and ISA extraction
- `external/instrument-amdgpu-kernels` — LLVM instrumentation plugins

When working on a sub-project, load both the top-level and sub-project knowledge trees.

## Build
See `build/` directory and `CMakeLists.txt`. Standard CMake workflow.

## Notes
- Documentation (README.md, etc.) is currently outdated. Prioritize source code when understanding the project.

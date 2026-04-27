# Omniprobe - Claude Code Instructions

## Project Overview

Omniprobe is a toolkit for instrumenting HIP/Triton GPU kernels to extract runtime
information such as memory access patterns, cache line usage, and LDS bank conflicts.

This repository uses the Agentic Meta Project v0.3 operating model. All agent
infrastructure lives under `.agents/`.

## Session Workflow

- **Start**: Run `/session-init` to bootstrap context.
- **During**: Work on tasks. Use `/pm-load` to load relevant PM units.
- **End**: Run `/session-close` to persist state and capture the session.

## Project Memory

Structured project knowledge lives in `.agents/pm/units/`. See `.agents/pm/pm-index.md`
for the unit registry. Load only what you need for the current task.

## Sub-projects

Two git submodules in `external/`:
- `external/dh_comms` — device-host communication library
- `external/kerneldb` — kernel database and ISA extraction

Note: `instrument-amdgpu-kernels` was absorbed into `src/instrumentation/` and is no
longer a submodule.

## Environment Variables

Project-local environment variables are defined in `.claude/session_init_primes.json`:
- `TRITON_DIR` — Triton repository path
- `TRITON_LLVM` — Triton's LLVM build directory
- `INSTRUMENTED_ROCBLAS_LIB_DIR` — instrumented rocBLAS library path
- `INSTRUMENTED_HIPBLASLT_LIB_DIR` — instrumented hipBLASLt library path

## Build

Standard CMake workflow. See `CMakeLists.txt` and `docs/building-from-source.md`.

## Workspace Boundaries

The omniprobe workspace is:
  `/work1/amd/rvanoo/repos/omniprobe` (and its mirror at `/home1/rvanoo/repos/omniprobe`)

Additional allowed workspaces: `~/repos/triton`, `~/repos/sandbox`.

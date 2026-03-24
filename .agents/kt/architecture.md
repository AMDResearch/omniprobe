# Omniprobe Architecture

## Overview
Omniprobe is a toolkit for instrumenting HIP/Triton GPU kernels to extract runtime information such as memory access patterns, cache line usage, and LDS bank conflicts.

**Recent Changes** (2026-03-24):
- Absorbed `instrument-amdgpu-kernels` submodule into `src/instrumentation/`
  (refactor `rf_absorb-instrumentation-plugins`, done). Replaced `ExternalProject_Add`
  with `add_instrumentation_plugins()` CMake function using `llvm-config` and custom
  commands. Removed `ext_proj_add.cmake`. Only dh_comms and kerneldb remain as submodules.

**Changes** (2026-03-23):
- Install tree restructure complete (`rf_install-tree-restructure`, done).
  Both build and install trees now use `<root>/omniprobe/{bin,lib,lib/plugins,lib/bitcode,config}`.
  `omniprobe` script derives all paths from its own location (`dirname(dirname(abspath(__file__)))`),
  eliminating `runtime_config.txt` dependency. Test scripts support `OMNIPROBE_ROOT` env var
  for install-tree testing.
- Unified kernel discovery for runtime-loaded code objects (refactor `rf_unify-kernel-discovery`, done).
  Instrumented kernels in `.hsaco` files loaded via `hipModuleLoad()` are now auto-discovered
  without `--library-filter` when both original and `__amd_crk_*` variants are in the same code object.
  Uses HSA symbol hook → `coCache::registerRuntimeKernel()` + AMD loader API v1.01 for lazy
  arg descriptor extraction. `--library-filter` still needed for external-file case.
- Added module-load kernel discovery test suite (3 tests, `run_module_load_tests.sh`).
  Handler tests now 22/22 passing.

**Changes** (2026-03-19):
- `containers/triton_install.sh` rewrite complete (refactor `rf_triton-install-script`, done).
  Script is now a standalone executable with `--triton-version` / `--local-sources` options.
  Builds LLVM with shared libraries into `${TRITON_REPO}/llvm-project/build/` (deterministic
  path, replaces old `~/.triton/llvm/llvm-<hash>-ubuntu-x64` approach).
- CI setup refactor complete (`rf_ci-setup.md`, archived to `done/`):
  - Two-tier container architecture: `toolchain.Dockerfile` (LLVM/Triton, ~4.5h)
    + `omniprobe.Dockerfile` (code build, ~10min)
  - Base image: `rocm/dev-ubuntu-24.04:7.2`
  - Workflows: `toolchain-image.yml`, `build.yml`, `triton-staleness-check.yml`
  - Successor: `rf_container-local.md` (clean up `.def`, `build.sh`, `run.sh`)

**Changes** (2026-03-08):
- Standalone `ROCm/hipBLASLt` and `ROCm/rocBLAS` repos are deprecated; source now
  in `ROCm/rocm-libraries` monorepo. Build/instrumentation docs should reference monorepo.
- Refactor dossier `rf_rocblas_maximal_support.md` created for migrating to monorepo
  builds and adding hipBLASLt TensileLite helper kernel instrumentation.
- Key finding: Tensile `asm_full` and `hip_full` kernel names are fundamentally different
  (6+ fields differ); cannot combine both for instrumentation. `hip_full` required.
- User documentation planned for `docs/` directory (tracked in git).

**Changes** (2026-03-03):
- Merged agents branch into main (22 commits across 4 repos)
- Deleted agents branches (local + remote) from all 4 repos after merge
- Removed passthrough wrapper classes for cleaner architecture
- Added end-to-end test infrastructure via `tests/run_handler_tests.sh`
- Created test kernels with `CHECK_HIP` macro for clean error handling
- Improved test code readability (replaced binary constants with enums)
- Consolidated L2 cache line size definitions into `gpu_arch_constants.h`
- Cleaned up instrument-amdgpu-kernels submodule: removed 5 unused plugins, simplified to 3 dh_comms-based plugins (commits 5a5d7e0, 8869a43)
- Added directory awareness reminders to KT (architecture.md + kt_workflows.md) to prevent relative path errors

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
| Instrumentation | `src/instrumentation/` | LLVM IR instrumentation plugins |
| omniprobe CLI | `omniprobe/omniprobe` | Python orchestrator script |
| Testing | `tests/` | End-to-end test infrastructure via omniprobe |

## Sub-projects (Git Submodules)

| Sub-project | Location | Description | KT Location |
|-------------|----------|-------------|-------------|
| dh_comms | `external/dh_comms/` | Device-host message passing | `external/dh_comms/.agents/kt/` |
| kerneldb | `external/kerneldb/` | ISA extraction, DWARF parsing | `external/kerneldb/.agents/kt/` |

Note: `instrument-amdgpu-kernels` was absorbed into `src/instrumentation/` (2026-03-24).
It is no longer a submodule. See `sub_instrument_amdgpu.md` for details.

### Working with Submodules

**IMPORTANT**: Use `git -C` for submodule git operations instead of `cd && git` compound commands.

**Why**: Compound `cd && git` commands trigger security prompts (bare repository attack prevention) and are error-prone with directory state. Using `git -C` is explicit, single-command, and avoids these issues.

```bash
# PREFERRED: Use git -C with absolute path
git -C "$(git rev-parse --show-toplevel)/external/dh_comms" status
git -C "$(git rev-parse --show-toplevel)/external/kerneldb" log -3

# ALSO OK: Separate commands (but requires tracking directory state)
cd external/dh_comms
git status

# AVOID: Compound cd && git (triggers security prompts)
cd external/dh_comms && git status
```

**Best practices**:
- Use `git -C <path>` for all submodule git operations
- Use `$(git rev-parse --show-toplevel)` to get repo root reliably
- Each submodule is independent git repo with its own branches, commits, remotes
- When non-git commands need to run in submodule, use separate `cd` then run commands

## Path Guidelines

**IMPORTANT**: All paths are derived from the omniprobe script's own location. Never hardcode paths.

### Build tree layout
```
build/
  bin/omniprobe          → ../../omniprobe/omniprobe (symlink)
  config/                → ../omniprobe/config (symlink)
  lib/*.so               (interceptor + handlers + runtime deps)
  lib/plugins/*.so       (LLVM instrumentation plugins, symlinks)
  lib/bitcode/*.bc       (dh_comms device bitcode, copies)
```

### Install tree layout
```
<prefix>/omniprobe/
  bin/omniprobe          (Python script)
  config/                (analytics.py, triton_config.py)
  lib/*.so               (interceptor + handlers + runtime deps)
  lib/plugins/*.so       (LLVM instrumentation plugins)
  lib/bitcode/*.bc       (dh_comms device bitcode)
```

### Path resolution
The `omniprobe` script uses `dirname(dirname(abspath(__file__)))` to find its root.
This works identically from both trees because the relative layout is the same.

### Test scripts
Test scripts accept `OMNIPROBE_ROOT` env var to override which tree to use:
```bash
# Build tree (default):
tests/run_handler_tests.sh

# Install tree:
OMNIPROBE_ROOT=/path/to/install/omniprobe tests/run_handler_tests.sh
```

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

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `HSA_TOOLS_LIB` | Points to liblogDuration64.so |
| `LOGDUR_HANDLERS` | Comma-separated list of handler .so files |
| `LOGDUR_INSTRUMENTED` | Enable instrumented kernel dispatch |
| `LLVM_PASS_PLUGIN_PATH` | Path to instrumentation plugin |
| `LOGDUR_LOG_FORMAT` | Output format (csv, json) |
| `LOGDUR_LIBRARY_FILTER` | Path to JSON config for library include/exclude filtering |
| `DH_COMMS_GROUP_FILTER_X/Y/Z` | Block index filters (N or N:M range) |

## Last Verified
Date: 2026-03-24

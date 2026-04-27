# Refactor: Absorb Instrumentation Plugins into Omniprobe

## Status
- [x] TODO
- [x] In Progress
- [ ] Blocked
- [x] Done

## Objective

Absorb the `instrument-amdgpu-kernels` git submodule into omniprobe proper and
replace the two `ExternalProject_Add` invocations with a CMake function that
creates plugin targets directly, called once per LLVM variant (ROCm, Triton).

The instrumentation plugins are not used outside omniprobe. Their existence as a
separate project is a historical artifact. Moving them into the main repo
simplifies the build system, eliminates race conditions between ExternalProject
build/install steps, and gives us direct target control for output directories
and install rules.

## Refactor Contract

### Goal

After this refactor:

- Source files from `external/instrument-amdgpu-kernels/` live in
  `src/instrumentation/` within the omniprobe repo
- A CMake function `add_instrumentation_plugins(SUFFIX <s> LLVM_DIR <dir>)`
  creates three plugin targets per invocation, using `llvm-config` to resolve
  LLVM paths (no `find_package(LLVM)`, no global imported targets)
- The function is called twice: once for ROCm LLVM, once for Triton LLVM
  (when `TRITON_LLVM` is defined)
- Plugin `.so` files land directly in `build/lib/plugins/` via
  `LIBRARY_OUTPUT_DIRECTORY` (no symlink hack)
- Install uses `install(TARGETS ...)` (no `install(DIRECTORY ...)` from
  ExternalProject build dirs)
- The `instrument-amdgpu-kernels` git submodule is removed
- `cmake_modules/ext_proj_add.cmake` is removed; its remaining logic for
  kerneldb and dh_comms (just `include_directories` + `add_subdirectory`)
  is inlined into `CMakeLists.txt`

### Non-Goals / Invariants
- ABI compatibility: n/a (no public ABI)
- API compatibility: n/a
- Performance constraints: none
- Threading model: unchanged
- The `instrument-amdgpu-kernels` GitHub repo can be archived later;
  that is out of scope for this refactor
- dh_comms and kerneldb remain submodules (unchanged)
- `getBitcodePath()` semantics unchanged: plugins find bitcode in
  `../bitcode/` relative to their own location

### Verification Gates
- Build: `cmake --build build` succeeds
- Tests (build tree): `./tests/run_handler_tests.sh` — 22/22
- Tests (build tree): `TRITON_DIR=... ./tests/triton/run_test.sh` — 5/5
- Install: `cmake --install build --prefix /tmp/omniprobe-test` produces correct tree
- Tests (install tree): `omniprobe -e` from install tree shows correct paths
- Clean rebuild from scratch passes all gates

## Scope

### Files Created

| File | Purpose |
|------|---------|
| `src/instrumentation/AMDGCNSubmitAddressMessages.cpp` | Copied from submodule `src/` |
| `src/instrumentation/AMDGCNSubmitBBStart.cpp` | Copied from submodule `src/` |
| `src/instrumentation/AMDGCNSubmitBBInterval.cpp` | Copied from submodule `src/` |
| `src/instrumentation/InstrumentationCommon.cpp` | Copied from submodule `src/` |
| `src/instrumentation/include/AMDGCNSubmitAddressMessage.h` | Copied from submodule `include/` |
| `src/instrumentation/include/AMDGCNSubmitBBInterval.h` | Copied from submodule `include/` |
| `src/instrumentation/include/AMDGCNSubmitBBStart.h` | Copied from submodule `include/` |
| `src/instrumentation/include/InstrumentationCommon.h` | Copied from submodule `include/` |
| `src/instrumentation/include/utils.h` | Copied from submodule `include/` |
| `cmake_modules/add_instrumentation_plugins.cmake` | CMake function module |

### Files Modified

| File | Changes |
|------|---------|
| `CMakeLists.txt` | Inline `ext_proj_add` for kerneldb/dh_comms; replace instrument-amdgpu-kernels ExternalProject calls and `symlink_plugins` target with `add_instrumentation_plugins()` calls; update install rules |
| `.gitmodules` | Remove instrument-amdgpu-kernels entry |

### Files Removed

| File | Reason |
|------|--------|
| `external/instrument-amdgpu-kernels/` | Submodule removed; code absorbed |
| `cmake_modules/ext_proj_add.cmake` | Logic inlined into CMakeLists.txt; no longer needed |

### Call Graph Impact

No runtime code changes. Only build system changes.

`getBitcodePath()` in `InstrumentationCommon.cpp` is copied as-is. It uses
`dladdr()` to find the plugin's `.so` location at runtime and looks for bitcode
in `../bitcode/` relative to the plugin directory. Since the plugin output
location (`lib/plugins/`) and bitcode location (`lib/bitcode/`) are unchanged,
this logic continues to work.

### Risks

1. **`llvm-config` output differences**: ROCm's `llvm-config --cppflags`
   returns one `-I` path; Triton's returns two (source + build include dirs).
   The function must handle both. Mitigation: use `--cppflags` output as-is
   (split into a list), rather than constructing paths manually.

2. **RTTI mismatch**: Each LLVM may have different RTTI settings. Mitigation:
   query `llvm-config --has-rtti` per invocation and set `-fno-rtti` per-target.
   (Currently both are NO, but the function should handle either.)

3. **Triton LLVM linking**: Triton plugins link against `LLVMCore`,
   `LLVMIRReader`, `LLVMLinker`. Without `find_package(LLVM)` imported targets,
   we need to resolve these libraries manually. Mitigation: use
   `llvm-config --libdir` to find them and `find_library()` with that dir
   as a hint, or use `llvm-config --link-shared --libs core irreader linker`.

4. **ROCm LLVM linking**: ROCm plugins do NOT explicitly link against LLVM
   libraries (they rely on being `dlopen()`d into a process that already has
   LLVM symbols). The function must only add LLVM link libraries for the
   Triton variant. Mitigation: add a `LINK_LLVM_LIBS` option to the function.

5. **`llvm-config` availability**: Both ROCm and Triton LLVM installations
   must have `llvm-config`. Verified: ROCm 7.2.0 has it at
   `${ROCM_PATH}/llvm/bin/llvm-config`; Triton LLVM build has it at
   `${TRITON_LLVM}/bin/llvm-config`.

6. **Submodule removal ordering**: Must absorb code and verify everything
   works BEFORE removing the submodule, so we can fall back if needed.

## Current State

### Current architecture
```
external/instrument-amdgpu-kernels/     (git submodule)
├── CMakeLists.txt                      (standalone project: find_package(LLVM), global state)
├── src/
│   ├── CMakeLists.txt                  (defines 3 plugin targets per suffix)
│   ├── AMDGCNSubmitAddressMessages.cpp
│   ├── AMDGCNSubmitBBStart.cpp
│   ├── AMDGCNSubmitBBInterval.cpp
│   └── InstrumentationCommon.cpp
└── include/
    ├── AMDGCNSubmitAddressMessage.h
    ├── AMDGCNSubmitBBInterval.h
    ├── AMDGCNSubmitBBStart.h
    ├── InstrumentationCommon.h
    └── utils.h
```

Parent `CMakeLists.txt` calls `ext_proj_add()` twice with `C_COMPILER` +
`BINARY_SUFFIX`, which triggers `ExternalProject_Add`. Each ExternalProject
gets its own CMake invocation in a separate build directory:
- `build/external/instrument-amdgpu-kernels-rocm/`
- `build/external/instrument-amdgpu-kernels-triton/`

A `symlink_plugins` custom target then creates symlinks from those build dirs
into `build/lib/plugins/`. Install rules use `install(DIRECTORY ...)` to copy
`.so` files from the ExternalProject build dirs.

### ext_proj_add.cmake behavior (cmake_modules/ext_proj_add.cmake)
- If `C_COMPILER` and `CXX_COMPILER` args are provided → `ExternalProject_Add`
  (used only for instrument-amdgpu-kernels)
- Otherwise → `add_subdirectory` (used for kerneldb, dh_comms)
- Also sets `${CAPS_NAME}_INCLUDE_DIR` and `${CAPS_NAME}_LIBRARIES` vars
- For kerneldb/dh_comms with `INCLUDE_DIRS` flag: adds `include_directories()`

### Parent CMakeLists.txt key sections (line references to current main)
- Lines 134-135: `include(ext_proj_add)`
- Lines 136-143: `ext_proj_add(NAME kerneldb ...)`, `ext_proj_add(NAME dh_comms ...)`
- Lines 145-150: Override submodule output dirs, set lib path vars
- Lines 151-156: `ext_proj_add(NAME instrument-amdgpu-kernels ... BINARY_SUFFIX "-rocm")`
- Lines 158-166: Triton variant: `set(LLVM_INSTALL_DIR ...)` + second `ext_proj_add` with
  `BINARY_SUFFIX "-triton"`
- Lines 168-200: `symlink_plugins` custom target
- Lines 268-280: Install rules for plugins (install DIRECTORY from ExternalProject build dirs)

### Subproject src/CMakeLists.txt key details
- Defines 3 plugins: `AMDGCNSubmitAddressMessages`, `AMDGCNSubmitBBStart`,
  `AMDGCNSubmitBBInterval`
- Each shares `InstrumentationCommon.cpp`
- Suffix detection: `set(install_suffix "triton")` then checks if
  `LLVM_INSTALL_DIR` matches `.*rocm.*` → sets `"rocm"`
- Targets: `${plugin}-${install_suffix}` (e.g., `AMDGCNSubmitAddressMessages-rocm`)
- Triton plugins link against `LLVMCore`, `LLVMIRReader`, `LLVMLinker`
  (imported targets from `find_package(LLVM)`)
- ROCm plugins do NOT link against LLVM libraries
- Headers via: `target_include_directories(... "${CMAKE_CURRENT_SOURCE_DIR}/../include")`

### Subproject top-level CMakeLists.txt global state (the root cause)
Sets extensive global CMake state that bleeds if used via `add_subdirectory()`:
- `CMAKE_CXX_COMPILER` / `CMAKE_C_COMPILER` (overwritten to ROCm clang)
- `CMAKE_PREFIX_PATH` (appended with LLVM cmake path)
- `find_package(LLVM)` creates global imported targets (LLVMCore, etc.)
- `include_directories(SYSTEM ${LLVM_INCLUDE_DIRS})` (global scope)
- `link_directories(${LLVM_LIBRARY_DIRS})` (global scope)
- `add_definitions(${LLVM_DEFINITIONS})` (global scope)
- `CMAKE_CXX_FLAGS` (appended with -Wall -Werror etc.)
- `CMAKE_CXX_STANDARD` set to 17 (parent uses 20)
- `CMAKE_RUNTIME/LIBRARY_OUTPUT_DIRECTORY` (global scope)

CMake also forbids calling `add_subdirectory()` on the same source dir twice.

### llvm-config verified output

**ROCm 7.2.0** (`/opt/rocm-7.2.0/llvm/bin/llvm-config`):
- `--version`: 22.0.0git
- `--has-rtti`: NO
- `--cppflags`: `-I/opt/rocm-7.2.0/lib/llvm/include -D_GNU_SOURCE -D_GLIBCXX_USE_CXX11_ABI=1 -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS`

**Triton LLVM** (`/home1/rvanoo/repos/triton/llvm-project/build/bin/llvm-config`):
- `--version`: 22.0.0git
- `--has-rtti`: NO
- `--cppflags`: `-I/home1/rvanoo/repos/triton/llvm-project/llvm/include -I/home1/rvanoo/repos/triton/llvm-project/build/include -D_GNU_SOURCE -D_DEBUG -D_GLIBCXX_ASSERTIONS -D_GLIBCXX_USE_CXX11_ABI=1 -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS`

Note: Triton has TWO include dirs (source + build); ROCm has one. Triton also
defines `_DEBUG` and `_GLIBCXX_ASSERTIONS` which ROCm does not.

### Problems with current approach
1. **Race conditions**: ExternalProject build/install steps interleave with
   the main build, causing occasional failures
2. **No direct target control**: Can't set properties on ExternalProject
   targets from the parent (they're opaque)
3. **Symlink indirection**: Extra `symlink_plugins` target needed to get
   plugins into the right place
4. **Install from build dirs**: `install(DIRECTORY ...)` with glob patterns
   instead of proper `install(TARGETS ...)`
5. **Submodule coordination**: Separate branches, commits, and version
   tracking for code that's only used here

## Design Decisions

### CMake function design

```cmake
# cmake_modules/add_instrumentation_plugins.cmake

function(add_instrumentation_plugins)
    cmake_parse_arguments(AIP "LINK_LLVM_LIBS" "SUFFIX;LLVM_DIR" "" ${ARGN})

    # 1. Find and validate llvm-config
    find_program(_llvm_config_${AIP_SUFFIX} llvm-config
        PATHS ${AIP_LLVM_DIR}/bin NO_DEFAULT_PATH REQUIRED)

    # 2. Query LLVM configuration (per-invocation, no global state)
    execute_process(COMMAND ${_llvm_config_${AIP_SUFFIX}} --cppflags
        OUTPUT_VARIABLE _llvm_cppflags OUTPUT_STRIP_TRAILING_WHITESPACE)
    execute_process(COMMAND ${_llvm_config_${AIP_SUFFIX}} --libdir
        OUTPUT_VARIABLE _llvm_libdir OUTPUT_STRIP_TRAILING_WHITESPACE)
    execute_process(COMMAND ${_llvm_config_${AIP_SUFFIX}} --has-rtti
        OUTPUT_VARIABLE _llvm_has_rtti OUTPUT_STRIP_TRAILING_WHITESPACE)

    # 3. Parse cppflags into include dirs and compile definitions
    #    (separate_arguments + filter -I vs -D flags)

    # 4. Create targets (no global state — all target_* commands)
    set(_instrumentation_src_dir ${CMAKE_CURRENT_SOURCE_DIR}/src/instrumentation)
    set(_plugins AMDGCNSubmitAddressMessages AMDGCNSubmitBBStart AMDGCNSubmitBBInterval)
    set(_all_targets "")

    foreach(plugin IN LISTS _plugins)
        set(_target ${plugin}-${AIP_SUFFIX})
        add_library(${_target} SHARED
            ${_instrumentation_src_dir}/${plugin}.cpp
            ${_instrumentation_src_dir}/InstrumentationCommon.cpp
        )
        target_include_directories(${_target} PRIVATE
            ${_instrumentation_src_dir}/include
            ${_llvm_include_dirs}  # extracted from --cppflags
        )
        target_compile_definitions(${_target} PRIVATE
            ${_llvm_definitions}  # extracted from --cppflags
            LLVM_DISABLE_ABI_BREAKING_CHECKS_ENFORCING
        )
        target_compile_options(${_target} PRIVATE
            -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function
            -fdiagnostics-color=always -fvisibility-inlines-hidden
            $<$<NOT:$<BOOL:${_llvm_has_rtti_bool}>>:-fno-rtti>
        )
        set_target_properties(${_target} PROPERTIES
            CXX_STANDARD 17
            CXX_STANDARD_REQUIRED ON
            LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib/plugins
        )

        # Conditional LLVM linking (Triton only)
        if(AIP_LINK_LLVM_LIBS)
            target_link_directories(${_target} PRIVATE ${_llvm_libdir})
            target_link_libraries(${_target} PRIVATE LLVMCore LLVMIRReader LLVMLinker)
        endif()

        list(APPEND _all_targets ${_target})
    endforeach()

    # 5. Export target list and install in one place
    set(INSTRUMENTATION_TARGETS_${AIP_SUFFIX} ${_all_targets} PARENT_SCOPE)
    install(TARGETS ${_all_targets} LIBRARY DESTINATION omniprobe/lib/plugins)
endfunction()
```

Key properties:
- **No global state**: all `target_*` commands, no `include_directories()` /
  `link_directories()` / `add_definitions()`
- **No `find_package(LLVM)`**: uses `llvm-config` instead, avoiding imported
  target conflicts
- **Per-target RTTI**: queries `--has-rtti` and sets `-fno-rtti` per-target
- **Per-target CXX_STANDARD**: 17 (isolated from parent's C++20)
- **Callable multiple times**: each call creates uniquely-suffixed targets
- **Self-contained install**: install rules inside the function
- **`LINK_LLVM_LIBS` option**: only Triton variant uses this

### Calling convention in parent CMakeLists.txt

```cmake
include(add_instrumentation_plugins)

add_instrumentation_plugins(
    SUFFIX rocm
    LLVM_DIR ${ROCM_PATH}/llvm
)

if(DEFINED TRITON_LLVM)
    add_instrumentation_plugins(
        SUFFIX triton
        LLVM_DIR ${TRITON_LLVM}
        LINK_LLVM_LIBS
    )
endif()
```

### Preserving git history

The submodule's git history is NOT merged into the parent repo. Instead:
- The original `instrument-amdgpu-kernels` GitHub repo is kept as-is
  (can be archived later, out of scope).
- The commit that copies the source files into `src/instrumentation/`
  references the submodule's HEAD commit hash, so the provenance is clear.
- If the full history is ever needed, it's available in the original repo.

This was chosen over `git subtree add` (which merges all submodule commits
into the parent history) for simplicity. If the executing session finds a
reason to prefer subtree merge, that's fine too.

### Source file location

`src/instrumentation/` with a private `include/` subdirectory. This keeps
the LLVM plugin code alongside other omniprobe source code while maintaining
a clear boundary (the plugins are compiled with different compilers and flags
than the rest of the project).

### LLVM library linking strategy

- **ROCm plugins**: No explicit LLVM linking. The plugins are loaded via
  `dlopen()` into `clang`, which already has all LLVM symbols.
- **Triton plugins**: Explicit linking against `LLVMCore`, `LLVMIRReader`,
  `LLVMLinker` (shared libraries from Triton's LLVM build). Use
  `llvm-config --libdir` to find them; link via `target_link_directories`
  + `target_link_libraries`.

The difference exists because ROCm's clang is a system-installed binary with
LLVM symbols available, while Triton's LLVM is a custom shared-library
build where the plugin needs explicit linkage.

### Inlining ext_proj_add for kerneldb and dh_comms

After removing the ExternalProject path, `ext_proj_add()` for kerneldb and
dh_comms reduces to ~4 lines each:
```cmake
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/external/kerneldb/include)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/external/kerneldb)
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/external/dh_comms/include)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/external/dh_comms)
```
Plus the `set_target_properties` calls that already exist for output dirs.
No need for a separate cmake module for this.

## Plan of Record

### Autonomous Execution Protocol

This refactor is designed for autonomous execution. After each micro-step:
1. **Commit** the change (one commit per step, on the feature branch)
2. **Run the gate** (build, test, or verification as specified)
3. **Update the dossier**: mark step done, note any discoveries or issues
4. **Commit the dossier update** alongside the code changes (or separately
   if the code commit was already made)

If a gate fails: diagnose, fix, and re-run before proceeding. Do NOT
accumulate breakage across steps.

If the session is interrupted, the dossier's progress log and checked-off
steps provide enough state to resume in a new session via `kt-refactor resume`.

### Build commands reference

Configure (from repo root, with Triton venv activated):
```bash
cmake -B build \
    -DROCM_PATH=/opt/rocm-7.2.0 \
    -DCMAKE_HIP_ARCHITECTURES=gfx90a \
    -DTRITON_LLVM=/home1/rvanoo/repos/triton/llvm-project/build \
    -DINTERCEPTOR_BUILD_TESTING=ON \
    -DCMAKE_INSTALL_PREFIX=$PWD/install
```

Build:
```bash
cmake --build build
```

Handler tests (need `LD_LIBRARY_PATH=build:$LD_LIBRARY_PATH`):
```bash
LD_LIBRARY_PATH=$PWD/build:$LD_LIBRARY_PATH ./tests/run_handler_tests.sh
```

Triton tests:
```bash
LD_LIBRARY_PATH=$PWD/build:$LD_LIBRARY_PATH ./tests/triton/run_test.sh
```

Install + verify:
```bash
cmake --install build --prefix /tmp/omniprobe-test
ls /tmp/omniprobe-test/omniprobe/lib/plugins/
```

### Micro-steps

#### Phase A: Absorb source files and create CMake function

1. [x] **Create feature branch** `rf/absorb-instrumentation-plugins` — Gate: branch exists
   - Create from `main`.
   - Commit: N/A (branch creation only)

2. [x] **Copy source files into `src/instrumentation/`** — Gate: files exist
   - Copy `external/instrument-amdgpu-kernels/src/*.cpp`
     → `src/instrumentation/`
   - Copy `external/instrument-amdgpu-kernels/include/*.h`
     → `src/instrumentation/include/`
   - Do NOT remove submodule yet (need it for fallback).
   - Commit message must reference the submodule's HEAD commit hash
     for provenance (e.g., "copy instrumentation plugin sources from
     instrument-amdgpu-kernels at <hash>").
   - Update dossier: mark step done.

3. [x] **Write `cmake_modules/add_instrumentation_plugins.cmake`** — Gate: N/A (tested in step 5)
   - Implement function as described in Design Decisions above.
   - Handle: LLVM discovery via `llvm-config`, per-target properties,
     conditional LLVM linking, RTTI detection, compiler flags, install rules.
   - Commit: "add CMake function for instrumentation plugin targets"
   - Update dossier: mark step done.

4. [x] **Integrate into parent `CMakeLists.txt`** — Gate: `cmake -B build ...` configures OK
   - Inline kerneldb/dh_comms `ext_proj_add` calls (replace with direct
     `include_directories` + `add_subdirectory`).
   - `include(add_instrumentation_plugins)` after the kerneldb/dh_comms
     subdirectory additions.
   - Call `add_instrumentation_plugins(SUFFIX rocm LLVM_DIR ${ROCM_PATH}/llvm)`.
   - Conditionally call with `SUFFIX triton LLVM_DIR ${TRITON_LLVM} LINK_LLVM_LIBS`.
   - Remove the two `ext_proj_add(NAME instrument-amdgpu-kernels ...)` calls,
     the `set(LLVM_INSTALL_DIR ...)` line, the `symlink_plugins` target, and
     the `include(ext_proj_add)` line.
   - Remove the old `install(DIRECTORY ... instrument-amdgpu-kernels-*/build/lib/ ...)`
     blocks (install rules are now inside the function).
   - Commit: "replace ExternalProject with add_instrumentation_plugins"
   - Update dossier: mark step done, record cmake configure output.

5. [x] **Build and verify** — Gate: build succeeds, `.so` files in `build/lib/plugins/`
   - Delete build dir and reconfigure from scratch (to avoid stale
     ExternalProject artifacts).
   - `cmake --build build`
   - Verify all 6 plugin `.so` files are produced (3 ROCm + 3 Triton).
   - Fix any build issues; commit fixes separately.
   - Update dossier: mark step done, note any issues and fixes.

#### Phase B: Verify correctness

6. [x] **Run handler tests** — Gate: 22/22 pass
   - `LD_LIBRARY_PATH=$PWD/build:$LD_LIBRARY_PATH ./tests/run_handler_tests.sh`
   - Fix any failures; commit fixes separately.
   - Update dossier: mark step done, record test results.

7. [x] **Run Triton tests** — Gate: 5/5 pass
   - `LD_LIBRARY_PATH=$PWD/build:$LD_LIBRARY_PATH ./tests/triton/run_test.sh`
   - Fix any failures; commit fixes separately.
   - Update dossier: mark step done, record test results.

8. [x] **Verify install tree** — Gate: correct layout, `omniprobe -e` works
   - `cmake --install build --prefix /tmp/omniprobe-test`
   - Verify tree matches expected layout (plugins in `omniprobe/lib/plugins/`).
   - `OMNIPROBE_ROOT=/tmp/omniprobe-test/omniprobe omniprobe -e` shows
     correct paths.
   - Update dossier: mark step done.

#### Phase C: Remove submodule and cleanup

9. [x] **Remove git submodule** — Gate: clean rebuild succeeds
    - `git submodule deinit -f external/instrument-amdgpu-kernels`
    - `git rm external/instrument-amdgpu-kernels`
    - Remove entry from `.gitmodules`
    - `rm -rf .git/modules/external/instrument-amdgpu-kernels`
    - Commit: "remove instrument-amdgpu-kernels submodule"
    - Clean rebuild to verify nothing depended on the submodule.
    - Update dossier: mark step done.

10. [x] **Remove `cmake_modules/ext_proj_add.cmake`** — Gate: build succeeds
    - File is no longer referenced after step 4 inlined its logic.
    - `git rm cmake_modules/ext_proj_add.cmake`
    - Commit: "remove ext_proj_add.cmake (logic inlined)"
    - Update dossier: mark step done.

11. [x] **Final verification** — Gate: clean rebuild from scratch, all tests pass
    - Delete `build/`, reconfigure from scratch, rebuild.
    - Handler tests: 22/22
    - Triton tests: 5/5
    - Install tree: correct layout
    - `omniprobe -e` from both trees
    - Update dossier: mark all done, record final commit hash, update
      Last Verified.

### Current Step

All steps complete.

## Rejected Approaches

- **`add_subdirectory()` twice on the submodule**: CMake does not allow calling
  `add_subdirectory()` on the same source directory twice. Additionally, the
  subproject's CMakeLists.txt creates extensive global state (`find_package(LLVM)`
  imported targets, `include_directories()`, `link_directories()`,
  `add_definitions()`, `CMAKE_CXX_FLAGS`) that would bleed across invocations.

- **Wrapper subdirectories**: Creating two thin CMakeLists.txt wrappers that
  each `include()` the subproject source. Technically viable but still requires
  refactoring the subproject to avoid global state, and doesn't address the
  fundamental issue that this code belongs in omniprobe.

- **Keep ExternalProject, fix race conditions**: This is the fallback if the
  current approach fails. Would involve adding proper `DEPENDS` declarations
  and coordinating install steps. Preserves the status quo architecture. If
  needed, a separate dossier (`rf_fix-external-project-races`) will be created.

## Open Questions

None currently.

## Fallback Plan

If the function-based approach proves unworkable (e.g., `llvm-config` output
is insufficient, compiler flag conflicts between LLVM variants), abandon this
branch and create a separate dossier `rf_fix-external-project-races` to
improve the existing ExternalProject approach instead.

## Progress Log

### Session 2026-03-24: Dossier created
- Surveyed: submodule CMakeLists.txt, src/CMakeLists.txt, ext_proj_add.cmake,
  parent CMakeLists.txt integration, include/ headers
- Verified: `llvm-config` available in both ROCm 7.2.0 and Triton LLVM builds
- Verified: both LLVM installations have RTTI disabled
- Verified: `--cppflags` returns correct include paths for both (ROCm: 1 path,
  Triton: 2 paths with source + build includes)
- Design decision: absorb submodule entirely (not just refactor CMake inclusion)
  since plugins are omniprobe-only code
- Design decision: inline ext_proj_add for kerneldb/dh_comms, remove the module
- Next: create feature branch and begin Phase A

### Session 2026-03-24: Refactor completed
- Completed all 11 micro-steps across 3 phases
- Commits: 2d3911b, dd6d9b7, 76b6141, 202e783, be27f3a, 49f4138
- Key discovery: LLVM plugins must be compiled with the matching LLVM's clang++,
  not hipcc. Initial approach using `add_library()` failed because CMake uses
  the project's `CMAKE_CXX_COMPILER` (hipcc) for all CXX targets. Switched to
  `add_custom_command()` to invoke clang++ from `llvm-config --bindir` directly.
- Also discovered: test targets depended on `symlink_plugins` target (removed).
  Updated to depend on `AMDGCNSubmitAddressMessages-rocm` directly.
- Gates passed: clean build, 22/22 handler tests, 5/5 Triton tests, install tree correct
- Branch: `rf/absorb-instrumentation-plugins` ready for merge

## Last Verified
Commit: 49f4138
Date: 2026-03-24

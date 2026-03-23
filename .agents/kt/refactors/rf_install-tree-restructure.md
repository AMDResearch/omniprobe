# Refactor: Install Tree Restructure

## Status
- [ ] TODO
- [x] In Progress
- [ ] Blocked
- [ ] Done

## Objective

Restructure the install tree from the current scattered layout (with legacy
`logDuration` subdirectories) to a clean, conventional `<prefix>/omniprobe/`
tree. Mirror the relative structure in the build tree so that both trees use
identical relative paths for installed artifacts.

## Refactor Contract

### Goal

After this refactor:

**Install tree** (`cmake --install --prefix <prefix>`):
```
<prefix>/omniprobe/
  bin/
    omniprobe                              (Python script)
  lib/
    liblogDuration64.so                    (interceptor)
    libdefaultMessageHandlers64.so         (handler plugin)
    libMemAnalysis64.so                    (handler plugin)
    libLogMessages64.so                    (handler plugin)
    libBasicBlocks64.so                    (handler plugin)
    libdh_comms.so                         (runtime dep)
    libkernelDB64.so                       (runtime dep)
  lib/plugins/
    libAMDGCNSubmitAddressMessages-rocm.so (LLVM plugin)
    libAMDGCNSubmitAddressMessages-triton.so
    libAMDGCNSubmitBBStart-rocm.so
    libAMDGCNSubmitBBStart-triton.so
    libAMDGCNSubmitBBInterval-rocm.so
    libAMDGCNSubmitBBInterval-triton.so
  lib/bitcode/
    dh_comms_dev_cdna2_co5.bc
    dh_comms_dev_cdna2_co6.bc
    dh_comms_dev_cdna3_co5.bc
    dh_comms_dev_cdna3_co6.bc
  config/
    analytics.py
    triton_config.py
```

**Build tree** (mirrors relative paths for installed artifacts):
```
build/
  lib/
    liblogDuration64.so                    (via LIBRARY_OUTPUT_DIRECTORY)
    libdefaultMessageHandlers64.so
    libMemAnalysis64.so
    libLogMessages64.so
    libBasicBlocks64.so
    libdh_comms.so
    libkernelDB64.so
  lib/plugins/
    libAMDGCNSubmit*.so                    (symlinks or copies from external/)
  lib/bitcode/
    dh_comms_dev_*.bc                      (replaces copy_bitcode_to_* targets)
  bin/
    omniprobe -> ../../omniprobe/omniprobe (symlink)
  config/ -> ../omniprobe/config           (symlink)
  external/                                (unchanged — ExternalProject dirs)
  tests/                                   (unchanged — test binaries)
  ...                                      (cmake cache, objects, etc.)
```

### Non-Goals / Invariants
- ABI compatibility: n/a (no public ABI)
- API compatibility: n/a
- Performance constraints: none
- Threading model: unchanged
- The `external/` ExternalProject build dirs remain where CMake puts them
- Soversion symlinks (libX.so.1, libX.so.1.0.0) can be dropped — these
  are not system libraries

### Verification Gates
- Build: `cmake --build build` succeeds (clean rebuild)
- Tests (build tree): `./tests/run_handler_tests.sh` (22/22)
- Tests (build tree): `TRITON_DIR=... ./tests/triton/run_test.sh` (5/5)
- Install: `cmake --install build --prefix /tmp/omniprobe-test` produces
  correct tree
- Tests (install tree): omniprobe -e from install tree shows correct paths
- Submodule commits are atomic within each submodule

## Scope

### Affected Files — Top-level repo

| File | Changes |
|------|---------|
| `CMakeLists.txt` | Install destinations, runtime_config.txt generation, output dirs |
| `cmake_modules/ext_proj_add.cmake` | ExternalProject CMAKE_INSTALL_PREFIX handling |
| `plugins/CMakeLists.txt` | Install destination, output directory |
| `src/CMakeLists.txt` | LIBRARY_OUTPUT_DIRECTORY for interceptor |
| `tests/test_kernels/CMakeLists.txt` | copy_bitcode targets → build/lib/bitcode/, INST_PLUGIN path, build-tree symlinks |
| `omniprobe/omniprobe` | Path resolution rewrite (derive from script location) |
| `tests/run_handler_tests.sh` | Build dir references |
| `tests/triton/run_test.sh` | Plugin path references |
| Test subscripts | Any hardcoded build/ paths |

### Affected Files — Submodules

| File | Changes |
|------|---------|
| `external/dh_comms/CMakeLists.txt` | Bitcode install dest: `lib` → `lib/bitcode`; LIBRARY_OUTPUT_DIRECTORY |
| `external/instrument-amdgpu-kernels/CMakeLists.txt` | Plugin install dest: `lib` → `lib/plugins` |
| `external/instrument-amdgpu-kernels/src/InstrumentationCommon.cpp` | `getBitcodePath()`: find `../bitcode/` relative to plugin |
| `external/kerneldb/src/CMakeLists.txt` | LIBRARY_OUTPUT_DIRECTORY (optional) |

### Risks
- **Big-bang coupling**: Moving .so outputs and updating test scripts must
  happen atomically. Mitigated by feature branch + build gate after each step.
- **ExternalProject install step**: `ext_proj_add` runs install during build,
  writing to CMAKE_INSTALL_PREFIX. Need to verify this still works or change
  the install prefix for the build-time install step.
- **dh_comms/kerneldb add_subdirectory**: Setting LIBRARY_OUTPUT_DIRECTORY
  may conflict with settings in their own CMakeLists.txt. Need to verify.
- **dladdr path in getBitcodePath()**: The `/lib/` stripping logic is fragile.
  Replacing it with explicit `../bitcode/` relative lookup is cleaner.

## Current State

### Current install layout
```
<prefix>/
  bin/logDuration/omniprobe, config/, runtime_config.txt
  lib/logDuration/liblogDuration64.so
  lib/logDuration/lib{defaultMessageHandlers,LogMessages,BasicBlocks,MemAnalysis}64.so
  lib/libdh_comms.so, libkernelDB64.so, dh_comms_dev_*.bc, libAMDGCN*.so
  include/{dh_comms,kerneldb}/...
  share/logDuration/test_kernels/*.hsaco
```

### Current build layout
```
build/
  lib{logDuration,defaultMessageHandlers,LogMessages,BasicBlocks,MemAnalysis}64.so  (flat in build/)
  external/dh_comms/lib/libdh_comms.so, dh_comms_dev_*.bc
  external/kerneldb/lib/libkernelDB64.so
  external/instrument-amdgpu-kernels-{rocm,triton}/build/lib/libAMDGCN*.so, dh_comms_dev_*.bc (copies)
```

### Current path resolution
- `runtime_config.txt`: baked `build_dir` and `install_dir` at cmake configure time
- `get_install_path()`: compares `install_dir/bin/logDuration` with script location
- `handler_lib_dir`: `build_dir` (build mode) or `install_dir/lib` (install mode)
- `base_llvm_pass_plugin`: points into `external/instrument-amdgpu-kernels-triton/build`
- `LD_LIBRARY_PATH`: prepends `handler_lib_dir`

### getBitcodePath() current behavior
- Uses `dladdr()` to find plugin .so location
- Strips filename → `PluginDir` (e.g., `.../build/lib`)
- If `PluginPath` contains `/lib/`: strips `PluginDir` at `/lib/` boundary
  - In build tree: `PluginDir.find("/lib/")` doesn't match (no trailing slash),
    so bitcode is found at `.../build/lib/dh_comms_dev_*.bc` (same dir as plugin)
  - In install tree: would strip to parent of `/lib/`, which is wrong for current layout
- Constructs `PluginDir + "/dh_comms_dev" + CDNAVersion + CodeObjectVersion + ".bc"`

### ext_proj_add() behavior
- dh_comms, kerneldb: `add_subdirectory()` — targets visible to parent
- instrument-amdgpu-kernels: `ExternalProject_Add()` — separate build + install
- ExternalProject passes `-DCMAKE_INSTALL_PREFIX=${CMAKE_INSTALL_PREFIX}`
  and runs install step during build (installs to final prefix as side effect)

## Plan of Record

### Micro-steps

#### Phase A: Build tree restructure

1. [ ] **Move top-level .so to build/lib/** — Gate: build
   - Set `LIBRARY_OUTPUT_DIRECTORY` on interceptor target (src/CMakeLists.txt)
   - Set `LIBRARY_OUTPUT_DIRECTORY` on handler plugin targets (plugins/CMakeLists.txt)
   - Set `LIBRARY_OUTPUT_DIRECTORY` on dh_comms and kernelDB targets (after
     add_subdirectory, from parent CMakeLists.txt)
   - Verify all .so files appear in `build/lib/`

2. [ ] **Move bitcode to build/lib/bitcode/** — Gate: build
   - Replace `copy_bitcode_to_rocm` target to copy to `${CMAKE_BINARY_DIR}/lib/bitcode/`
   - Replace `copy_bitcode_to_triton` target similarly
   - Update `INST_PLUGIN` path in tests/test_kernels/CMakeLists.txt (will be
     needed after step 3)

3. [ ] **Create build/lib/plugins/ with LLVM plugin .so files** — Gate: build
   - Add custom target to symlink (or copy) ExternalProject plugin .so files
     from `external/instrument-amdgpu-kernels-*/build/lib/` to `build/lib/plugins/`
   - Depends on `instrument-amdgpu-kernels-rocm` and `-triton` targets

4. [ ] **Update getBitcodePath()** — Gate: build + compile test kernel
   - In `external/instrument-amdgpu-kernels/src/InstrumentationCommon.cpp`:
   - Replace `/lib/` stripping logic with: find plugin dir via `dladdr()`,
     replace trailing path component (`plugins`) with `bitcode`
   - Construct: `PluginDir/../bitcode/dh_comms_dev_{arch}_{cov}.bc`
   - Commit in instrument-amdgpu-kernels submodule

5. [ ] **Create build/bin/ and build/config/ symlinks** — Gate: build
   - `build/bin/omniprobe` → `../../omniprobe/omniprobe`
   - `build/config/` → `../omniprobe/config/` (or copy)
   - Add cmake custom commands for these

6. [ ] **Update omniprobe script path resolution** — Gate: handler tests pass
   - Derive `root_dir` from script's own location: `dirname(dirname(__file__))`
     (works because script is at `<root>/bin/omniprobe` in both trees via symlink)
   - `lib_dir = root_dir + "/lib"`
   - `plugin_dir = root_dir + "/lib/plugins"`
   - `config_dir = root_dir + "/config"`
   - Remove `runtime_config.txt` dependency for path resolution
   - Keep `runtime_config.txt` only for `triton_llvm` flag (or find another way)
   - Update `handler_lib_dir`, `base_llvm_pass_plugin`, `base_hsa_tools_lib`
   - Update `config_path`

7. [ ] **Update test scripts** — Gate: 22/22 handler tests + 5/5 Triton
   - `tests/run_handler_tests.sh` and subscripts: update omniprobe path, build dir refs
   - `tests/triton/run_test.sh`: update plugin path
   - Any other test scripts referencing build dir artifacts

#### Phase B: Install tree restructure

8. [ ] **Update cmake install rules** — Gate: cmake --install produces correct tree
   - Root CMakeLists.txt:
     - Interceptor: `lib/${DEST_NAME}` → `omniprobe/lib`
     - Script: `bin/${DEST_NAME}` → `omniprobe/bin`
     - Config: `bin/${DEST_NAME}` → `omniprobe/config`
     - runtime_config.txt: `bin/${DEST_NAME}` → `omniprobe/` (or eliminate)
   - plugins/CMakeLists.txt: `lib/${DEST_NAME}` → `omniprobe/lib`
   - src/CMakeLists.txt (hsaco): `share/${PROJECT_NAME}/test_kernels` → `omniprobe/share/test_kernels`
   - dh_comms: lib → `omniprobe/lib`, bitcode → `omniprobe/lib/bitcode`,
     headers → `omniprobe/include/dh_comms`
   - kerneldb: lib → `omniprobe/lib`, headers → `omniprobe/include/kerneldb`
   - instrument-amdgpu-kernels: `lib` → `omniprobe/lib/plugins`
   - Adjust `ext_proj_add` CMAKE_INSTALL_PREFIX if needed to get the
     `omniprobe/` prefix for ExternalProject installs

9. [ ] **Verify install tree** — Gate: correct directory tree
   - `cmake --install build --prefix /tmp/test-install`
   - Verify all files at expected locations
   - Verify omniprobe -e shows correct paths from install tree

10. [ ] **Drop soversion symlinks** — Gate: build + install
    - Remove VERSION/SOVERSION properties from interceptor and submodule targets
    - Verify only bare .so files (no .so.1, .so.1.0.0)

#### Phase C: Cleanup

11. [ ] **Remove DEST_NAME / logDuration references** — Gate: build + install
    - Remove `DEST_NAME` variable from CMakeLists.txt
    - Grep for any remaining `logDuration` references and clean up
    - Update CPACK settings if needed

12. [ ] **Final test pass** — Gate: all tests pass from both trees
    - Handler tests from build tree (22/22)
    - Triton tests from build tree (5/5)
    - omniprobe -e from install tree
    - Clean rebuild from scratch

### Current Step

Phase A, Step 1 (not started)

## Design Decisions

### runtime_config.txt elimination

The build-tree symlink approach (`build/bin/omniprobe → ../../omniprobe/omniprobe`)
lets the script derive all paths from its own location using `dirname(dirname(__file__))`.
This eliminates the need for baked-in `build_dir` and `install_dir` values.

The `triton_llvm` flag can be handled by checking whether `lib/plugins/libAMDGCN*-triton.so`
exists, rather than reading it from a config file.

### ExternalProject install prefix

Currently, `ext_proj_add` passes `CMAKE_INSTALL_PREFIX=${CMAKE_INSTALL_PREFIX}` to
ExternalProject, causing it to install to the final prefix during build. For the new
layout, the ExternalProject needs to install to `${CMAKE_INSTALL_PREFIX}/omniprobe/`.

**Decision**: Change `ext_proj_add` to pass
`-DCMAKE_INSTALL_PREFIX=${CMAKE_INSTALL_PREFIX}/omniprobe`. Submodules keep their
generic install rules (`lib/`, `lib/plugins/`, etc.) and remain usable outside
omniprobe. The top-level project controls the `omniprobe/` namespace via the
install prefix it passes down.

For `add_subdirectory` submodules (dh_comms, kerneldb): set
`CMAKE_INSTALL_PREFIX` in the parent scope before `add_subdirectory()`, or use
`install(... DESTINATION omniprobe/...)` in the top-level install rules that
reference these targets. The latter is cleaner since `add_subdirectory` targets
are visible to the parent.

### dh_comms / kerneldb install destinations

These are `add_subdirectory` projects, so their install() rules run as part of
the parent's install step. Since we don't want to modify their install rules
(they may be used standalone), the top-level CMakeLists.txt should override
their install destinations. CMake doesn't directly support this for
add_subdirectory targets, so the cleanest approach is: set
`CMAKE_INSTALL_PREFIX` to `${original_prefix}/omniprobe` before calling
`add_subdirectory()` for these projects (and restore it after if needed),
or use the `COMPONENT` mechanism to separate omniprobe's install from the
submodules' defaults. Determine best approach during implementation.

## Progress Log

### Session 2026-03-23: Dossier created
- Completed research: ext_proj_add macro, getBitcodePath() logic, install rules,
  omniprobe script path resolution, copy_bitcode targets
- Discovered: getBitcodePath() `/lib/` stripping is a latent no-op in build tree
  (only fires if `/lib/` appears mid-path, not at end)
- Discovered: ExternalProject install step runs during build (side effect)
- Merged rf_omniprobe-runtime-paths to main (prerequisite fix)
- Design: build tree mirrors install tree via output dirs + symlinks

## Rejected Approaches

- **Copy (not symlink) omniprobe script to build/bin/**: Would create a stale
  copy that doesn't track source edits during development. Symlink preferred.
- **Set CMAKE_LIBRARY_OUTPUT_DIRECTORY globally**: Would affect all targets
  including test executables, which should stay in `build/tests/`.
- **Move ExternalProject build dirs**: Fighting ExternalProject's directory
  structure is fragile. Better to symlink/copy outputs to the mirrored layout.

## Open Questions

- ~~Should the install tree include `include/` and `share/` directories?~~ **Resolved**: No, omit both.
  Install tree will only contain `bin/`, `lib/`, `lib/plugins/`, `lib/bitcode/`, and `config/`.

## Last Verified
Commit: N/A
Date: 2026-03-23

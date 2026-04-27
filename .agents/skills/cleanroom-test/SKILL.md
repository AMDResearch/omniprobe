---
name: cleanroom-test
description: Run cleanroom build+test from build tree, install tree, and relocated install tree.
disable-model-invocation: false
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
---

# Cleanroom Test

Cleanroom build and test verification for omniprobe. Builds from scratch, then runs
the full test suite from three locations: build tree, install tree, and relocated install tree.
Use after major refactors or before merging feature branches.

## Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `--install-dir DIR` | `~/repos/sandbox` | Install prefix (omniprobe installs under `DIR/omniprobe/`) |
| `--relocate-dir DIR` | `DIR/relocate` | Relocated install prefix |
| `--skip-build` | (off) | Skip clean rebuild, use existing build tree |
| `--skip-rocblas` | (off) | Skip rocBLAS and hipBLASLt tests even if on a compatible filesystem |

## Instructions

### 0. Parse Arguments

Parse arguments from the skill invocation. Apply defaults for anything not specified:
- `INSTALL_DIR`: `~/repos/sandbox` (expand `~`)
- `RELOCATE_DIR`: `${INSTALL_DIR}/relocate`
- `SKIP_BUILD`: false
- `SKIP_ROCBLAS`: false

### 1. Environment Detection

Detect and report the environment before starting:

```
Cleanroom Test — Environment
  Repository:    /work1/amd/rvanoo/repos/omniprobe
  Branch:        <current branch>
  HEAD:          <short hash + subject>
  Install dir:   <INSTALL_DIR>/omniprobe
  Relocate dir:  <RELOCATE_DIR>/omniprobe
  ROCM_PATH:     <path>
  TRITON_LLVM:   <path or "not set">
  GPU:           <rocminfo output>
```

**Filesystem detection**: For each of the three test locations (build dir, install dir,
relocate dir), check the filesystem type using `stat -f -c '%t'`. The virtiofs magic
number is `0x564d5346` (but some kernels report `UNKNOWN (0x18031977)` for GPFS — that
is NOT virtiofs). If ANY location is on virtiofs (`%T` output contains `virtiofs` OR
magic is `564d5346`), record a warning to be displayed at the end.

Also check for the GPFS magic `0x18031977` — GPFS supports `mmap()` fine, so it does
NOT trigger the virtiofs warning.

**Instrumented library discovery** (unless `--skip-rocblas`):

Auto-discover instrumented rocBLAS and hipBLASLt libraries by searching known locations:

1. Check `INSTRUMENTED_ROCBLAS_LIB_DIR` and `INSTRUMENTED_HIPBLASLT_LIB_DIR` env vars
2. Search common locations:
   - `~/repos/sandbox/rocblas_maximal_support/rocblas-install/lib` (rocBLAS)
   - `~/repos/sandbox/rocblas_maximal_support/hipblaslt-install/lib64` (hipBLASLt)
   - `/tmp/rocblas-install/lib` (rocBLAS)
   - `/tmp/hipblaslt-install` (hipBLASLt)
3. Verify found directories contain the expected files:
   - rocBLAS: `librocblas.so` in the directory (do NOT use `nm` to verify instrumentation —
     fat binary GPU kernels are embedded in `.hip_fatbin` ELF sections and invisible to `nm`)
   - hipBLASLt: `libhipblaslt.so` in the directory, plus `hipblaslt/library/*.hsaco`

If auto-discovery fails for either library, use `AskUserQuestion` to ask the user:
- Present auto-discovered paths (if any partial matches found)
- Allow the user to provide a custom path
- Allow the user to say "not available" to skip that library's tests
- Ask about both libraries in a single question if both are missing

Record the final paths (or "skipped") for use in all three test phases.

### 2. Clean and Build (unless --skip-build)

**CRITICAL**: The install and relocate directories must be wiped COMPLETELY before anything
else happens. Verify they are gone after deletion — if they still exist, something went wrong.

```bash
# Remove any existing install — MUST verify deletion
rm -rf ${INSTALL_DIR}/omniprobe
rm -rf ${RELOCATE_DIR}/omniprobe
# Verify they're gone
[ -d "${INSTALL_DIR}/omniprobe" ] && echo "ERROR: failed to remove install dir" && exit 1
[ -d "${RELOCATE_DIR}/omniprobe" ] && echo "ERROR: failed to remove relocate dir" && exit 1

# Clean build tree
rm -rf build

# Configure
cmake -B build \
    -DROCM_PATH=/opt/rocm-7.2.0 \
    -DCMAKE_HIP_ARCHITECTURES=gfx90a \
    -DTRITON_LLVM=/home1/rvanoo/repos/triton/llvm-project/build \
    -DINTERCEPTOR_BUILD_TESTING=ON \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}

# Build (parallel)
cmake --build build -j$(nproc)
```

If `--skip-build`, only remove the install dirs (not the build tree).

**Gate**: Build must succeed. If it fails, stop and report the error.

### 3. Phase 1 — Test from Build Tree

**LD_LIBRARY_PATH isolation**: Save the baseline `LD_LIBRARY_PATH` before starting any phase.
At the start of each phase, reset `LD_LIBRARY_PATH` to the saved baseline before adding the
phase-specific paths. This prevents paths from accumulating across phases.

```bash
# Save baseline (do this ONCE before Phase 1)
BASELINE_LD_LIBRARY_PATH="${LD_LIBRARY_PATH}"

# Phase 1 paths
export LD_LIBRARY_PATH=$PWD/build:$BASELINE_LD_LIBRARY_PATH
```

Run the full test suite using the build tree's omniprobe:

```bash
# Handler tests (22 tests)
./tests/run_handler_tests.sh

# Library filter chain (5 tests) — use timeout to avoid hangs
timeout 120 ./tests/library_filter_chain/run_test.sh

# Triton tests (5 tests) — if TRITON_LLVM was set at configure time
TRITON_DIR=/home1/rvanoo/repos/triton ./tests/triton/run_test.sh

# rocBLAS tests — unless on virtiofs, --skip-rocblas, or "not available"
INSTRUMENTED_ROCBLAS_LIB_DIR=${ROCBLAS_LIB_DIR} ./tests/rocblas_filter/run_test.sh

# hipBLASLt tests — unless on virtiofs, --skip-rocblas, or "not available"
INSTRUMENTED_HIPBLASLT_LIB_DIR=${HIPBLASLT_LIB_DIR} ./tests/hipblaslt/run_test.sh

# rocBLAS + hipBLASLt combined — only if BOTH are available
INSTRUMENTED_ROCBLAS_LIB_DIR=${ROCBLAS_LIB_DIR} \
INSTRUMENTED_HIPBLASLT_LIB_DIR=${HIPBLASLT_LIB_DIR} \
./tests/rocblas_hipblaslt/run_test.sh
```

Where `ROCBLAS_LIB_DIR` and `HIPBLASLT_LIB_DIR` are the paths discovered/confirmed
in Step 1. If a library was marked "not available", don't set its env var (the test
script will skip automatically).

If `library_filter_chain` times out (exit code 124), record it as a WARNING, not a hard
failure. The test may hang on some configurations — this is a known issue.

Record results (tests passed, failed, skipped) for the build-tree phase.

**Important about virtiofs and rocBLAS/hipBLASLt**: The mmap issue affects the filesystem
where the instrumented library `.so` / `.hsaco` files reside, not where omniprobe is
installed. Check the filesystem of `ROCBLAS_LIB_DIR` and `HIPBLASLT_LIB_DIR` specifically.
If those are on virtiofs, skip those tests and add a warning.

### 4. Phase 2 — Test from Install Tree

```bash
# Install
cmake --install build --prefix ${INSTALL_DIR}

# Remove ALL omniprobe artifacts from build tree so they cannot leak into tests.
# Keep ONLY test kernel binaries and test-specific libraries (under build/tests/).
# The build tree has:
#   build/lib/         — runtime .so files (REMOVE)
#   build/bin/         — symlink to source omniprobe script (REMOVE)
#   build/config       — symlink to source config dir (REMOVE)
#   build/lib/plugins/ — instrumentation plugins (REMOVE, via lib/ removal)
#   build/lib/bitcode/ — .bc files (REMOVE, via lib/ removal)
#   build/tests/       — test binaries and .hsaco files (KEEP)
rm -rf build/lib build/bin build/config
# Verify removal
[ -d build/lib ] && echo "ERROR: build/lib still exists" && exit 1
[ -d build/bin ] && echo "ERROR: build/bin still exists" && exit 1
[ -L build/config ] && echo "ERROR: build/config symlink still exists" && exit 1

# Reset LD_LIBRARY_PATH to baseline and set install tree paths
export LD_LIBRARY_PATH=${INSTALL_DIR}/omniprobe/lib:$BASELINE_LD_LIBRARY_PATH
export OMNIPROBE_ROOT=${INSTALL_DIR}/omniprobe
```

Run the same test suite as Phase 1, but with `OMNIPROBE_ROOT` set.

**Verification**: Before running tests, confirm that `OMNIPROBE_ROOT/bin/omniprobe` exists
and that no `.so` files remain under `build/lib/`. Print the `OMNIPROBE_ROOT` being used.

**Note**: Test kernel binaries remain in `build/tests/test_kernels/` — only the
omniprobe runtime (lib/*.so, bin/omniprobe, lib/plugins/*.so) comes from the install tree.

### 5. Phase 3 — Test from Relocated Install Tree

```bash
# Move install tree to new location
mkdir -p ${RELOCATE_DIR}
mv ${INSTALL_DIR}/omniprobe ${RELOCATE_DIR}/omniprobe
# Verify the old location is gone and the new one exists
[ -d "${INSTALL_DIR}/omniprobe" ] && echo "ERROR: install dir not moved" && exit 1
[ ! -d "${RELOCATE_DIR}/omniprobe" ] && echo "ERROR: relocate dir not created" && exit 1

# Reset LD_LIBRARY_PATH to baseline and set relocated tree paths
export LD_LIBRARY_PATH=${RELOCATE_DIR}/omniprobe/lib:$BASELINE_LD_LIBRARY_PATH
export OMNIPROBE_ROOT=${RELOCATE_DIR}/omniprobe
```

Run the same test suite as Phase 1, but with `OMNIPROBE_ROOT` pointing to the relocated
install tree. This verifies that omniprobe resolves all paths relative to its own location
and doesn't depend on hardcoded install paths.

**Verification**: Confirm `build/lib/` and `build/bin/` are still absent (from Phase 2
cleanup). Confirm `OMNIPROBE_ROOT/bin/omniprobe` exists at the relocated path.

### 6. Report

Print a consolidated summary:

```
================================================================================
Cleanroom Test Results
================================================================================
Phase 1 (build tree):      22/22 handler, 5/5 filter, 5/5 triton, ...
Phase 2 (install tree):    22/22 handler, 5/5 filter, 5/5 triton, ...
Phase 3 (relocated tree):  22/22 handler, 5/5 filter, 5/5 triton, ...

⚠ WARNINGS:
  - rocBLAS/hipBLASLt tests skipped: <install_dir> is on virtiofs (mmap incompatible)
  - Instrumented rocBLAS not found at /tmp/rocblas-install/lib (skipped)

Overall: PASS / FAIL
================================================================================
```

**Important**: Warnings about virtiofs and skipped suites MUST appear at the very end,
after all results, so the user doesn't miss them.

### 7. Cleanup

Do NOT clean up automatically. Leave the install and relocated trees in place so the user
can inspect them if needed. The user can delete them manually.

## Practical Notes

### Build tree isolation (CRITICAL)

In Phases 2 and 3, the build tree MUST be stripped of all omniprobe runtime artifacts so
that tests cannot accidentally use them instead of the install/relocated tree. Specifically:

- `build/lib/` — contains all `.so` files, plugins, and bitcode. **DELETE entirely.**
- `build/bin/` — contains a symlink `omniprobe → source_tree/omniprobe/omniprobe`.
  **DELETE entirely.** If left in place, test scripts that derive paths from `REPO_ROOT`
  would find this symlink and use it instead of the install tree's omniprobe.
- `build/config` — symlink to source config dir. **DELETE.**
- `build/tests/` — contains compiled test kernel binaries and `.hsaco` files. **KEEP.**
  These are the test programs themselves, not part of the omniprobe runtime.

After deletion, verify with `ls build/lib build/bin 2>&1` that they are gone.

### Other notes

- The `library_filter_chain` tests build their own test libraries. They should work from
  any tree since they use the `OMNIPROBE` path from `test_common.sh`.
- Scope filter tests (part of handler tests) recompile kernels — they use the plugin from
  `OMNIPROBE_ROOT/lib/plugins/`, so they test the correct tree.
- Module-load tests use `.hsaco` files from the build tree (`BUILD_DIR/tests/test_kernels/`).
- The rocBLAS/hipBLASLt tests use external instrumented libraries. Their `mmap()` behavior
  depends on the filesystem where those libraries are installed, not where omniprobe is.
  The virtiofs check should apply to the rocBLAS/hipBLASLt lib dirs specifically.
- The `INSTRUMENTED_ROCBLAS_LIB_DIR` must point to the dir containing `librocblas.so`.
  The `INSTRUMENTED_HIPBLASLT_LIB_DIR` must point to the dir containing `libhipblaslt.so`
  (with `hipblaslt/library/*.hsaco` underneath).

## Iteration

If any test fails and requires code modifications:
1. Note the failure and what fix is needed
2. Make the fix
3. Consider whether the fix affects earlier phases
4. Continue with remaining phases
5. After all phases, if any fixes were made, re-run the entire cleanroom test

The skill should tell the user when iteration is needed and ask whether to proceed.

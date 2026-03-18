# Refactor: Update Triton Installation Script

## Status
- [ ] TODO
- [x] In Progress
- [ ] Blocked
- [ ] Done

## Objective

Rewrite `containers/triton_install.sh` to build Triton with a custom shared-library LLVM
that supports Omniprobe instrumentation. The script must work both standalone (auto-detecting
latest versions) and in CI (with explicit version overrides).

## Problem Statement

The current `triton_install.sh` is outdated:
- Triton pinned to commit `368c864e9` (predates all tagged releases; latest is v3.6.0)
- PyTorch pinned to `rocm6.2.4` (latest stable is rocm7.1)
- LLVM build is conditional and uses wrong arguments (no `-DBUILD_SHARED_LIBS=ON`)
- The `-l` and `-c` options are no longer needed
- Uses old `pip install -e python` instead of `pip install . --no-build-isolation`
- Patches Triton source after install (fragile with non-editable installs)
- No ROCm prerequisite check

Omniprobe requires LLVM built with shared libraries (`-DBUILD_SHARED_LIBS=ON`) so that
its LLVM pass plugins can link against the same LLVM libraries that Triton uses.

## Source Material

- Current script: `containers/triton_install.sh`
- LLVM shared libs build notes: `~/repos/notes-rene/build_triton+llvm.md`
- Triton README (build instructions): https://github.com/triton-lang/triton/blob/main/README.md
- Triton's LLVM build helper: `scripts/build-llvm-project.sh` (in the Triton repo)
- CI update plan: `.untracked/ci_update.md`

## Design Decisions

### Script interface

Options:
- `--triton-version <tag|commit>` — Triton version to build (default: auto-detect latest
  release tag via GitHub API)
- `--pytorch-rocm <version>` — PyTorch ROCm wheel index version (default: auto-detect
  highest stable index <= installed ROCm version)
- `-g <commit>` — alias for `--triton-version` (retained for backward compatibility)
- `-h` / `--help` — show usage

Remove `-l` (llvm-build-dir) and `-c` (clang-path) options.

### Prerequisites

The script requires:
- ROCm installed, `ROCM_PATH` set and pointing to a valid installation
- Network access (cloning repos, querying APIs, downloading packages)
- Python 3 with pip and venv

Check `ROCM_PATH` at the top of the script; fail early with a clear message if not set
or if `${ROCM_PATH}/llvm/bin/clang` doesn't exist.

### Build order

1. **Auto-detect versions** (if not specified via arguments)
   - Triton: query `https://api.github.com/repos/triton-lang/triton/releases/latest`
   - PyTorch ROCm: scrape `https://download.pytorch.org/whl/`, find highest `rocmX.Y`
     where X.Y <= installed ROCm version (derived from `ROCM_PATH`)

2. **Clone Triton** at the detected/specified version
   - `git clone https://github.com/triton-lang/triton.git`
   - `git checkout <tag or commit>`

3. **Patch Triton source** (before install, not after)
   - Patch `python/triton/backends/amd/compiler.py`: comment out
     `assert len(names) == 1` — this assertion fails when instrumentation clones kernels
   - Patching before install means both `-e` and regular `pip install .` work

4. **Build LLVM with shared libraries**
   - Use Triton's `scripts/build-llvm-project.sh` with custom CMake arguments
   - Key arguments from `~/repos/notes-rene/build_triton+llvm.md`:
     ```
     NUM_PROCS=$(nproc) scripts/build-llvm-project.sh \
       -G Ninja \
       -DCMAKE_BUILD_TYPE=RelWithDebInfo \
       -DLLVM_CCACHE_BUILD=OFF \
       -DLLVM_ENABLE_ASSERTIONS=ON \
       -DCMAKE_C_COMPILER=${ROCM_PATH}/llvm/bin/clang \
       -DCMAKE_CXX_COMPILER=${ROCM_PATH}/llvm/bin/clang++ \
       -DLLVM_ENABLE_LLD=ON \
       -DBUILD_SHARED_LIBS=ON \
       -DLLVM_OPTIMIZED_TABLEGEN=ON \
       -DMLIR_ENABLE_BINDINGS_PYTHON=OFF \
       -DLLVM_ENABLE_ZSTD=OFF \
       -DLLVM_TARGETS_TO_BUILD=Native\;NVPTX\;AMDGPU \
       -DCMAKE_EXPORT_COMPILE_COMMANDS=1 \
       -DLLVM_ENABLE_PROJECTS=clang\;mlir\;llvm\;lld \
       -DCMAKE_INSTALL_PREFIX=${TRITON_REPO}/llvm-project/install \
       -B${TRITON_REPO}/llvm-project/build \
       ${TRITON_REPO}/llvm-project/llvm
     ```
   - This step does NOT require the Python venv or pip dependencies
   - The LLVM commit hash is determined by Triton's `cmake/llvm-hash.txt` and is
     handled automatically by `scripts/build-llvm-project.sh`

5. **Create venv, install Python dependencies**
   - `python3 -m venv .venv --prompt triton`
   - `source .venv/bin/activate`
   - Build-time deps: `pip install ninja cmake wheel pybind11`
   - Run-time deps: `pip install matplotlib pandas`
   - PyTorch: `pip3 install torch torchvision --index-url https://download.pytorch.org/whl/rocm${PYTORCH_ROCM_VERSION}`
   - Remove conflicting Triton: `pip uninstall --yes pytorch-triton-rocm`

6. **Build and install Triton with shared LLVM**
   - Clean old build artifacts: `rm -rf python/triton/_C build compile_commands.json`
   - Set environment variables pointing to the custom LLVM build:
     ```
     CC=${TRITON_REPO}/llvm-project/build/bin/clang \
     CXX=${TRITON_REPO}/llvm-project/build/bin/clang++ \
     LLVM_BUILD_PATH=${TRITON_REPO}/llvm-project/build \
     LLVM_BUILD_SHARED_LIBS=1 \
     TRITON_BUILD_WITH_CLANG_LLD=1 \
     TRITON_BUILD_WITH_CCACHE=0 \
     LLVM_INCLUDE_DIRS=${TRITON_REPO}/llvm-project/build/include \
     LLVM_LIBRARY_DIR=${TRITON_REPO}/llvm-project/build/lib \
     LLVM_SYSPATH=${TRITON_REPO}/llvm-project/build \
     pip install . --no-build-isolation
     ```
   - Use `pip install .` (not `-e .`) for CI/container use

7. **Set environment variables and report paths**
   - `export TRITON_HIP_LLD_PATH="${ROCM_PATH}/llvm/bin/ld.lld"`
   - Since we verified ROCm at the start, this path is known to be valid
   - Note: `omniprobe` also sets this at runtime (line 270 of `omniprobe/omniprobe`),
     so this is mainly for standalone Triton use outside Omniprobe
   - **Export/print the LLVM build path** so downstream consumers know where it is.
     Omniprobe's CMake needs `-DTRITON_LLVM=${TRITON_REPO}/llvm-project/build`.
     CI workflows, Dockerfiles, and Apptainer defs all reference this path.

### Important: LLVM install location has changed

The **old** CI approach:
- Triton's build process downloaded/built its own LLVM into `~/.triton/llvm/llvm-<hash>-ubuntu-x64/`
- CI tarballed `~/.triton/` and passed it as an artifact between jobs
- Omniprobe was built with `-DTRITON_LLVM=$HOME/.triton/llvm/llvm-*ubuntu-x64`
- The Dockerfile hardcoded `ENV TRITON_LLVM=/root/.triton/llvm/llvm-7ba6768d-ubuntu-x64`

The **new** approach:
- We build LLVM ourselves via `scripts/build-llvm-project.sh` into
  `${TRITON_REPO}/llvm-project/build/`
- Setting `LLVM_SYSPATH` during Triton install prevents Triton from downloading
  its own LLVM, so `~/.triton/llvm/` is NOT populated
- `~/.triton/` may still be used by Triton at runtime as a kernel compilation cache,
  but the LLVM that Omniprobe needs is in the Triton repo tree
- The path is deterministic (no glob patterns like `llvm-*ubuntu-x64`)
- Omniprobe should be built with `-DTRITON_LLVM=${TRITON_REPO}/llvm-project/build`

This affects:
- `containers/omniprobe.Dockerfile` (currently hardcodes `TRITON_LLVM=/root/.triton/...`)
- `containers/omniprobe.def` (Apptainer equivalent)
- `.github/workflows/ubuntu.yml` and `redhat.yml` (matrix entry `$HOME/.triton/llvm/llvm-*`)
- Any documentation referencing `~/.triton`

### Open question: TRITON_HIP_LLD_PATH in Omniprobe context

The `omniprobe` Python script already sets `TRITON_HIP_LLD_PATH` at runtime
(`omniprobe/omniprobe:270`). Need to verify this is also set when building Omniprobe
with Triton support (`-DTRITON_LLVM=...` in CMake) and when running the Triton tests.
Check during validation.

## Implementation Steps

### Step 1: Rewrite `containers/triton_install.sh` ✅ (Session 2026-03-18a)

Implement the design above. The script should:
- Be sourceable (current script uses `source`; keep this for venv activation)
- Print clear progress messages for each phase
- Fail fast on errors (`set -e` or explicit error checks)
- Report the versions used at the end (Triton tag, LLVM hash, PyTorch version,
  ROCm index)

### Step 2: Test locally — build Triton ✅ (Session 2026-03-18b)

Test environment:
- Machine: 128-core wekafs (not virtiofs), 503 GiB RAM
- Triton repo: `~/repos/triton` with v3.6.0 checked out
- ROCm 7.2.0 at `/opt/rocm-7.2.0`
- GPU: gfx90a with `sramecc+:xnack-`

Results:
- LLVM built successfully (7608/7608 targets, ~30 min on 128 cores)
- All shared libraries verified present
- Triton v3.6.0 built and installed successfully
- PyTorch 2.10.0+rocm7.1 installed (Python 3.12 venv required; 3.9 lacks wheels)
- Assertion patch applied at `third_party/amd/backend/compiler.py`
- Critical fix: `CMAKE_PREFIX_PATH` and `PATH` needed in Triton build step
  (commit ab56562 on `rf/triton-install-script`)

### Step 3: Test locally — build Omniprobe against new Triton ✅ (Session 2026-03-18b)

- Built with `-DTRITON_LLVM=/home1/rvanoo/repos/triton/llvm-project/build`
- All targets built: liblogDuration64.so, handler plugins, test binaries
- Both `-rocm` and `-triton` instrumentation plugins link correctly
- Triton plugins verified linking against custom LLVM (not ROCm's):
  `libLLVMCore.so.22.0git => .../triton/llvm-project/build/./lib/...`

### Step 4: Test locally — run Omniprobe tests ✅ (Session 2026-03-18b)

- Handler tests: **19/19 pass** (3 basic, 6 block filter, 3 library filter, 7 scope)
- Triton integration tests: **5/5 pass** (plugin invocation, dispatch, cache line
  report, bank conflicts report, scope filtering)
- Note: `LD_LIBRARY_PATH` must include the build directory for `dlopen` to find
  handler libraries. This is a pre-existing issue, not caused by our changes.
- Note: Triton venv needs `pyfiglet` installed for omniprobe to run.

### Step 5: End-to-end script validation

Clean-room test of the script from scratch:
1. Remove `~/repos/triton` (or work in a fresh directory)
2. Source the script: `source containers/triton_install.sh`
   (proxy vars are saved/unset/restored by the script automatically)
3. Verify everything completes without manual intervention
4. Build Omniprobe against the resulting LLVM
5. Run Omniprobe handler tests + Triton integration tests

If any step requires manual tweaking, fix the script and repeat. Iterate until
the script runs cleanly from start to finish.

The Omniprobe build and test steps (5-6) are validation only — they confirm the
script's output is usable, but aren't part of the script itself.

### Step 6: Update CI references

Once validated, update `.untracked/ci_update.md` with results and any
adjustments needed for the CI workflow integration.
Deferred — not part of this refactoring scope. Tracked separately.

## Files Modified

- `containers/triton_install.sh` — complete rewrite

## Files Read (reference only)

- `~/repos/notes-rene/build_triton+llvm.md` — LLVM shared libs build instructions
- `omniprobe/omniprobe` — check TRITON_HIP_LLD_PATH usage
- `containers/omniprobe.Dockerfile` — references triton_install.sh
- `containers/omniprobe.def` — Apptainer definition, may reference triton_install.sh
- `.github/workflows/build-triton-ubuntu.yml` — current CI Triton build
- `.github/workflows/build-triton-redhat.yml` — current CI Triton build

## Cleanup Items

- **Consistent pip usage**: The current script mixes `pip` and `pip3` (e.g., `pip install`
  for build deps but `pip3 install torch ...` for PyTorch). These may point to different
  Python installations outside a venv. The new script should use `pip` consistently,
  since all installs happen inside the activated venv where `pip` is unambiguous.
  Alternatively, use `python3 -m pip` throughout for maximum safety.

## Risk Assessment

- **LLVM build arguments may need adjustment**: The notes in `build_triton+llvm.md` were
  accurate as of January 2026 but the Triton LLVM build script may have changed. Verify
  against the latest `scripts/build-llvm-project.sh` during implementation.
- **PyTorch ROCm version mismatch**: The highest available stable PyTorch ROCm index
  (currently 7.1) may lag behind the installed ROCm version (7.2). This is expected to
  work but should be verified.
- **Triton source patch may move**: The `assert len(names) == 1` line in
  `python/triton/backends/amd/compiler.py` could move or change in newer Triton versions.
  The patch function should handle this gracefully (warn if not found, don't fail).

### Current Step

Step 5: End-to-end script validation (next session).

## Progress Log

### Session 2026-03-18b (continued on 128-core wekafs machine)
- Completed: Steps 2, 3, 4
- Commits: ab56562 (fix CMAKE_PREFIX_PATH + PATH in Triton build step)
- Gates passed:
  - LLVM built with shared libraries (7608 targets)
  - Triton v3.6.0 built and installed against shared LLVM
  - Omniprobe built with `-DTRITON_LLVM=~/repos/triton/llvm-project/build`
  - Both ROCm and Triton instrumentation plugins link correctly
  - Handler tests: 19/19 pass
  - Triton integration tests: 5/5 pass
- Discovered:
  - **ROCm LLVM vs custom LLVM ambiguity**: Both ROCm 7.2.0's LLVM and our custom
    LLVM report version 22.0.0git. Without `CMAKE_PREFIX_PATH`, cmake's
    `find_package(LLVM)` finds ROCm's copy first, which lacks NVPTX targets needed
    by Triton's MLIR. Fix: `CMAKE_PREFIX_PATH="${LLVM_BUILD_DIR}"`.
  - **PATH needed for TRITON_BUILD_WITH_CLANG_LLD**: Triton's setup.py passes
    `-DCMAKE_C_COMPILER=clang` (bare name) when `TRITON_BUILD_WITH_CLANG_LLD=1`.
    The LLVM build dir's `bin/` must be in PATH so cmake can resolve it.
  - **PyTorch rocm7.1 requires Python 3.10+**: No cp39 wheels available. Must use
    Python 3.10+ for the venv.
  - **HTTP proxy causes SSL errors and slow downloads**: Bypassed with
    `env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY`.
  - **Triton venv needs pyfiglet**: The omniprobe script imports pyfiglet, which
    isn't in Triton's default dependencies. Must `pip install pyfiglet` in the venv.
  - **LD_LIBRARY_PATH pre-existing issue**: Handler libraries in the build dir aren't
    found by `dlopen` unless `LD_LIBRARY_PATH` includes the build directory. Not
    caused by our changes. Root cause analysis:
    - When `-a Heatmap` (or any named analyzer) is used, `omniprobe` resolves
      the name via `analytics_config[h]['lib_name']` (in `omniprobe/config/analytics.py`),
      which yields a **bare filename** like `libdefaultMessageHandlers64.so`.
    - This bare name is passed to `LOGDUR_HANDLERS` env var, and the C++ code does
      `dlopen("libdefaultMessageHandlers64.so", ...)` — which needs `LD_LIBRARY_PATH`.
    - The **default handler** path (when no `-a` is given, line 556) uses an absolute
      path like `build/libdefaultMessageHandlers64.so`, which works without
      `LD_LIBRARY_PATH`.
    - The `omniprobe` script sets `LD_LIBRARY_PATH` to `get_omniprobe_home()/lib`
      (lines 434-438), which is the omniprobe script's own directory + `/lib` — this
      path doesn't exist in the build tree.
    - Previous test sessions (2026-03-12) likely passed because `LD_LIBRARY_PATH` was
      already set in the shell environment from prior setup steps.
    - **Fix options** (not part of this refactor, tracked separately):
      (a) `omniprobe` could prepend `build_dir` to `LD_LIBRARY_PATH` when in build mode,
      (b) the analytics config could use absolute paths based on install_path, or
      (c) line 779 could prepend build_dir to bare lib_names.
- Script updated: commit 91c601c adds Python 3.10+ detection and pyfiglet.

### Session 2026-03-18a
- Completed: Step 1 (script rewrite, 3 commits on branch `rf/triton-install-script`)
- Gates passed:
  - Script runs through Steps 1-3 correctly: prereq check, version auto-detection
    (Triton v3.6.0, PyTorch rocm7.1), clone, checkout, patch
  - Assertion patched at correct new path (`third_party/amd/backend/compiler.py`)
- Discovered:
  - **Assertion file moved**: In Triton v3.6.0, the assertion is in
    `third_party/amd/backend/compiler.py`, not the old
    `python/triton/backends/amd/compiler.py`. Patch function now searches both paths.
  - **v3.6.0 build script lacks LLVM_BUILD_SHARED_LIBS env var**: The `LLVM_BUILD_SHARED_LIBS`
    env var in `build-llvm-project.sh` was added after v3.6.0 (only in HEAD). Fixed by
    passing all CMake args as positional arguments instead.
  - **virtiofs is prohibitively slow**: Git operations on 172K LLVM files and the build
    itself are extremely slow on virtiofs. User will switch to a non-virtiofs machine
    with 4x cores for the next session.
  - **Log message stdout capture bug**: `log_info` calls inside `detect_triton_version()`
    and `detect_pytorch_rocm_version()` were captured by `$(...)`, polluting the return
    values. Fixed by redirecting to stderr inside those functions.

## Rejected Approaches

- **Using LLVM_BUILD_SHARED_LIBS env var**: Triton v3.6.0's `build-llvm-project.sh` doesn't
  support this env var (added later in HEAD). Must pass `-DBUILD_SHARED_LIBS=ON` as a
  positional CMake argument instead.
- **TRITON_CODEGEN_BACKENDS env var**: Setting this to `amd` to avoid NVPTX dependency
  does NOT work — Triton's `setup.py` always passes `nvidia;amd` to cmake regardless.
- **cmake 3.x vs 4.x**: The MLIR find_package error was not caused by cmake version.
  Both cmake 3.31.10 and 4.x produce the same error when finding ROCm's LLVM.

## Last Verified
Commit: 91c601c
Date: 2026-03-18

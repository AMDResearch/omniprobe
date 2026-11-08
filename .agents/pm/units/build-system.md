# Build System

## Responsibility

CMake-based build system for omniprobe. Handles multi-LLVM-variant plugin
compilation (ROCm and Triton), install tree layout, environment variable
configuration, and external dependency management (submodules, ROCm, LLVM).

## Key Source Files

| File | Purpose |
|------|---------|
| `CMakeLists.txt` | Top-level build configuration |
| `src/CMakeLists.txt` | Interceptor library build |
| `plugins/CMakeLists.txt` | Handler plugin builds |
| `tests/CMakeLists.txt` | Test kernel compilation |
| `tests/test_kernels/CMakeLists.txt` | Test kernel targets with `-g` and `-fpass-plugin` |
| `cmake_modules/add_instrumentation_plugins.cmake` | CMake function for building instrumentation plugins per LLVM variant |
| `src/instrumentation/*.cpp` | Instrumentation plugin sources — there is no `CMakeLists.txt` here; the plugins are built by `add_instrumentation_plugins.cmake`, called from the top-level `CMakeLists.txt` |

## Key Types and Classes

N/A — CMake infrastructure, no C++ types.

## Key Functions and Entry Points

| Function | Location | Purpose |
|----------|----------|---------|
| `add_instrumentation_plugins()` | `cmake_modules/add_instrumentation_plugins.cmake` | Called once per LLVM variant (ROCm, Triton) to build instrumentation plugins |

## Data Flow

### Multi-LLVM-Variant Build

Instrumentation plugins must match the LLVM they will be loaded into. The build system
compiles each plugin twice:

- **ROCm variant:** `add_instrumentation_plugins(SUFFIX rocm LLVM_DIR ${ROCM_PATH}/llvm)`
- **Triton variant:** `add_instrumentation_plugins(SUFFIX triton LLVM_DIR ${TRITON_LLVM} LINK_LLVM_LIBS)`

Plugins are compiled using the variant's own `clang++` (from `llvm-config --bindir`),
NOT `hipcc`.

### Build Tree Layout

```
build/
├── lib/
│   └── liblogDuration64.so          # Main tool library
├── plugins/
│   └── lib*.so                      # Handler plugin shared libraries
└── src/instrumentation/
    └── lib*.so                      # LLVM IR instrumentation plugins
```

### Install Tree Layout

```
<prefix>/
├── lib/
│   └── liblogDuration64.so
├── lib/omniprobe/plugins/
│   └── lib*.so
├── lib/omniprobe/instrumentation/
│   └── lib*.so
└── bin/
    └── omniprobe                    # Python orchestrator
```

### Bitcode Location

Bitcode is located via `getBitcodePath()`: looks in `../bitcode/` relative to the plugin
directory.

In the **build tree** too (2026-11-08, `31eb907`): the top-level `copy_bitcode` target populates
`build/lib/bitcode/` in every build with all dh_comms bitcode, exact-arch variants included, so
build-tree plugins find it without an install. A missing or unreadable bitcode file is a fatal
compile error, not a silent skip — see `instrumentation`.

### Standard Build Command

```bash
cmake -B build -DROCM_PATH=/opt/rocm-7.2.0 -DCMAKE_HIP_ARCHITECTURES=gfx90a \
  -DTRITON_LLVM=<triton-repo>/llvm-project/build \
  -DINTERCEPTOR_BUILD_TESTING=ON \
  -DCMAKE_INSTALL_PREFIX=$PWD/install
cmake --build build
cmake --install build
```

`<triton-repo>` must be a Triton checkout at the version pinned in `containers/toolchain.Dockerfile`
(v3.9.0 as of 2026-11-08), built with `containers/triton_install.sh`, and given as an absolute
path. Keep the local test environment's `TRITON_DIR` on the same tree: a suite run against a
Triton other than the pinned one passes green and proves the wrong thing.

**Re-configuring an existing tree with a new `-DTRITON_LLVM` now picks up the new LLVM**
(`664c417`, `cmake_modules/add_instrumentation_plugins.cmake`): `find_program` caches
`_llvm_config_<suffix>`, and before the fix a re-configure kept building the `-triton` plugins
against the old LLVM (measured: plugin still linked `libLLVMCore.so.23.0git`, which Triton v3.9.0
then failed to load). The cached path is now dropped when it is not `<LLVM_DIR>/bin/llvm-config`.
If a plugin's LLVM soname looks wrong after a bump, check this first (`ldd` the plugin).

## Environment Variables

### Build-time Variables

| Variable | Purpose |
|----------|---------|
| `ROCM_PATH` | ROCm installation prefix (e.g., `/opt/rocm-7.2.0`) |
| `CMAKE_HIP_ARCHITECTURES` | Target GPU architecture (e.g., `gfx90a`) |
| `TRITON_LLVM` | Triton's LLVM build directory (must be absolute path) |
| `INTERCEPTOR_BUILD_TESTING` | Enable GoogleTest integration (OFF by default) |
| `CMAKE_INSTALL_PREFIX` | Install prefix (must be set — default `/` causes permission error) |

### Runtime Variables

| Variable | Purpose |
|----------|---------|
| `LD_PRELOAD` | Set to `liblogDuration64.so` to load the rocprofiler-sdk tool |
| `LOGDUR_HANDLERS` | Comma-separated list of handler shared libraries to load |
| `LOGDUR_LOG_FORMAT` | Output format: `console` (default), `csv`, or `json` |
| `LOGDUR_LIBRARY_FILTER` | Colon-separated list of libraries to include for scanning |
| `LOGDUR_LIBRARY_FILTER_EXCLUDE` | Colon-separated list of libraries to exclude from scanning |
| `LLVM_PASS_PLUGIN_PATH` | Triton mode: path to instrumentation plugin for JIT compilation |
| `INSTRUMENTATION_SCOPE` | Restrict instrumentation to specific source file/lines |
| `INSTRUMENTATION_SCOPE_FILE` | File containing instrumentation scope specification |

## Invariants

- `TRITON_LLVM` must be an absolute path — `~` is not expanded in ExternalProject sub-builds.
- `CMAKE_INSTALL_PREFIX` must be set explicitly — the default causes permission errors.
- `LD_LIBRARY_PATH` must include `build/` when running tests from a clean build (`.so` files
  not in install tree until `cmake --install`).
- Submodules (`dh_comms`, `kerneldb`) must be initialized before building.
- ROCm, HSA runtime, and rocprofiler-sdk are required dependencies.

## Dependencies

- `architecture` — system overview and data flow context
- `instrumentation` — plugins built by this system
- `testing` — test kernels compiled by this system

## Negative Knowledge

- **Do NOT use `hipcc` for instrumentation plugins.** They must be compiled with the LLVM
  variant's own `clang++` to match the LLVM they will be loaded into.
- **GoogleTest is disabled by default** (`INTERCEPTOR_BUILD_TESTING=OFF`). Do not enable
  without handler refactoring for dependency injection.

## CI container layering, and what it can and cannot prove (2026-10-26)

Two workflows, deliberately split:

- `.github/workflows/toolchain-image.yml` builds `omniprobe-toolchain:<VERSION>-rocm7.2` and
  `:latest-rocm7.2` from `containers/toolchain.Dockerfile` (LLVM + Triton, ~4.5h). It triggers
  **only** on changes to `toolchain.Dockerfile`, `containers/triton_install.sh`, `.dockerignore`
  or `VERSION`, plus manual dispatch.
- `.github/workflows/build.yml` pulls `:latest-rocm7.2` and builds omniprobe inside it
  (~10 min, 25 min timeout).

**`build.yml` runs `cmake --build build --target install` and stops.** No `ctest`, no
`run_all_tests.sh`, and `runs-on: ubuntu-latest` — **no GPU**. So CI is a compile gate only.
Anything whose failure mode is semantic rather than a compile error is invisible to it; see
`instrumentation`'s note on `validateAMDGPUTarget`.

**Bumping `TRITON_VERSION` is what triggers the 4.5h job.** The image is pushed only on success,
so a failed rebuild leaves `main` pinning a version that `latest-rocm7.2` does not contain, and
`build.yml` then silently builds against the stale image. Validate locally before bumping.

**A green `build.yml` right after a bump proves nothing until you check the digest.** A push
that changes the Dockerfile triggers both workflows at once, so the first `build.yml` pulls the
*old* image. To verify a build used the new one, compare the `Digest: sha256:…` on its
`docker pull` line with the manifest list the toolchain run pushed
(`pushing manifest for …:latest-rocm7.2@sha256:…`). Then `gh workflow run build.yml`.

**Two-stage toolchain image with a cache checkpoint (`913ae31`, 2026-10-27).** The Dockerfile
has an `llvm` stage (apt + LLVM build) and a `toolchain` stage (`FROM llvm`; Triton wheel), and
`toolchain-image.yml` builds `--target llvm` with `outputs: type=cacheonly` first. Reason:
**BuildKit exports cache only when a solve succeeds** — a failure in the Triton step discarded a
completed ~2h LLVM build (2026-10-26 run: imports, zero exports). Now each step exports its own
cache. In logs the phrases are `preparing build cache for export` / `cache export … done` — **not**
`exporting cache`; grepping for the latter returns 0 on a successful export and once nearly got the
checkpoint reported broken. `TRITON_VERSION` is declared **once**, as a global `ARG` before the
first `FROM`, re-declared bare per stage — `triton-staleness-check.yml` greps for the defaulted
assignment and must find exactly one, and a comment quoting it counts too.

**Why external PRs never get CI (measured 2026-10-26).** Two stacked blockers:
1. `gh api repos/AMDResearch/omniprobe/actions/permissions/fork-pr-contributor-approval` →
   `{"approval_policy":"all_external_contributors"}`. Fork-PR runs wait for a maintainer's
   approval; five of the six open fork PRs (#37–#40, #42) have **no run at all**. #44's single
   run had no jobs and no logs — it never started.
2. Downstream of that: `build.yml` interpolates `secrets.DOCKERHUB_USERNAME` (login step and
   `IMAGE`), and GitHub passes no secrets to fork `pull_request` runs, so even an approved run
   would pull `/omniprobe-toolchain:latest-rocm7.2` (empty repo part) and fail. Inferred from the
   workflow + GitHub docs, never observed. A public toolchain image with no login step would
   remove it. Related: issue #20. Full write-up `.untracked/fork-pr-ci-findings-2026-10-26.md`.

**`main` is branch-protected (since 2026-10-27):** force-pushes and deletion blocked,
`enforce_admins` on (the maintainer account is an admin, so without it the protection would not
apply to that account's pushes), no required reviews or status checks — direct pushes still work.

## Triton pin: v3.9.0 (bumped 2026-11-08, `ecb9a4c`)

LLVM pin `b010a18d` (**LLVM 24**: plugins now link `libLLVM*.so.24.0git`). Validated on gfx90a
(MI210, ROCm 7.2.0) before moving the pin: omniprobe compiles `-Werror` against LLVM 24 in both
plugin variants with **no source change**; full suite green. `containers/toolchain.def`
(Apptainer) now mirrors `toolchain.Dockerfile` — same version, LLVM-pin resolution and
verification, jq; it had been left on v3.7.1. Packet: `.agents/workflows/done/rf_triton-v3.9-bump/`.

What v3.9.0 needed from `containers/triton_install.sh`:

- **nanobind `==2.10.2`** installed (`8f49b37`; Triton v3.9.0's `setup.py` imports it).
- **Python >= 3.11** (`8f49b37`; v3.9.0 requires `>=3.11,<3.16`); the script probes
  `python3.13`..`python3.11`, `python3` and errors otherwise.
- **`LLVMMIRParser` patched into `TritonAMDMIRDAG`'s link list** (`5eba213`). Upstream defect:
  the library calls `llvm::createMIRParser` but links only `LLVMCodeGen`, so against a
  **shared-library** LLVM `triton-opt`/`triton-reduce`/`triton-lsp`/`triton-tensor-layout` fail
  with undefined `llvm::MIRParser` symbols. Not reported upstream.
- The v3.9.0 build downloads a prebuilt AMD codegen library at configure time (a separate,
  third LLVM: dh_comms bitcode from ROCm clang, core on LLVM 24, Triton codegen on its own).

Behaviour on the Triton path (`artifacts.md` of the packet has the method):

- Module triple is now **`amdgpu9.0a-amd-amdhsa`** (triton-lang/triton#11532); matched by
  `e6db747`. Bitcode selection is unchanged: Triton modules still log "Could not determine
  target architecture, defaulting to cdna2" (see `instrumentation`, `rf_exact-arch-bitcode`).
- **Instrumented output unchanged vs v3.8.0**, measured on three kernels (masked vector add,
  `tl.dot` matmul with LDS, row softmax) under `-i -a AddressLogger -t json` and
  `-i -a MemoryAnalysis -t json`, fresh `TRITON_CACHE_DIR` per run: identical per-location record
  counts, lanes and address sets, identical MemoryAnalysis JSON after normalising dispatch_id,
  timestamps and line numbers inside Triton's own `language/standard.py` (which moved). dh_comms
  still fully inlined (`s_swappc` 0); instruction counts within 0.2%. Re-use this method for the
  next bump: two runs of the old version first, to show the comparison is deterministic.
- `tests/triton/run_test.sh` now honours `BUILD_DIR` (`f48753c`); before, a run against a scratch
  tree silently tested `build/`'s plugin.

## Triton pin history: v3.8.0 (bumped 2026-10-26, `7f18d4b`)

LLVM pin `5f07f818` (2026-08-17, a cherry-pick merge in triton-lang's fork — mainline
`llvm/llvm-project` serves it too). Validated before the bump on gfx90a: omniprobe compiles
`-Werror` against it in both plugin variants, full suite 11/11, **no source changes needed**.
The image built in CI on the second attempt (run `40382090175`), and `build.yml` against it on
2026-10-27. What changed across v3.7.1 → v3.8.0, and what we did:

- **The pin moved from `cmake/llvm-hash.txt` to `cmake/llvm-info.json`, read with
  `jq -r '.llvm_hash'`** in Triton's `scripts/build-llvm-project.sh:9`. That script has no
  `set -e` and ends with `ninja`: an empty or `null` hash makes `git reset --hard` fail
  non-fatally and it builds **whatever commit the tree is on, exiting 0**. A caller's `set -e`
  cannot catch it. Two triggers, both measured: jq missing (empty), and jq present but key
  absent — real jq 1.8.2 prints `null` and exits **0**; only `-e` makes it exit 1. **Fixed on
  our side in `e18e4bb`**, without patching Triton's script: jq is a declared prerequisite
  (preflight in `triton_install.sh`, `jq` in the Dockerfile apt layer); the pin is read with
  `jq -re`, both layouts handled, exported as `LLVM_COMMIT_HASH` so Triton's lookup never runs
  (a caller-supplied `LLVM_COMMIT_HASH` is respected — custom-LLVM builds stay supported); and
  the tree's HEAD is **compared with the pin after the build** — verify the outcome, not the
  exit status. Confirmed in CI: `LLVM commit (pinned)` and `LLVM commit verified` both `5f07f818`.
  jq is a single static binary, user-installable in `~/bin` without root.
- **The final report reads `git rev-parse HEAD` of the tree, not the pin file** — it reports
  what was built rather than what was intended, and it works under `--skip-llvm`, which is the
  path the container takes (`EXPECTED_LLVM` is not set there).
- **Triton's CMake configure now downloads the NVIDIA toolchain** (CUPTI etc.) with
  `COMMAND_ERROR_IS_FATAL ANY` (`CMakeLists.txt:146`); v3.7.1 did this from `setup.py`. A CDN TLS
  blip (curl exit 35) failed the first CI run after ~2h — hence the checkpoint above.
  `-DTRITON_OFFLINE_BUILD=ON` exists but is not a free skip: it raises unless every dependency
  path is supplied.
- **Not in v3.8.0, and both matter for the next bump:** triton-lang/triton#10849 (keep the target
  machine with a plugin loaded — makes PR #44 live on the Triton path) and #11532 (subarch-aware
  triples — handled in advance by `e6db747`; see `instrumentation`).
- Things that did **not** need changing: the `assert len(names) == 1` patch (still matches, now
  at `compiler.py:540`), the `LLVM_PROJECT_URL` override, and v3.8.0's new
  `LLVM_DISTRIBUTION_COMPONENTS` / `*_UTILS` defaults — those govern only the `distribution` /
  install targets, and nothing here installs LLVM; the build tree is consumed directly.
  **Tripwire:** if anyone shrinks the image by consuming `llvm-project/install` instead of the
  39 GB build tree, that list becomes load-bearing.

The local LLVM mirror's remote must point at `https://github.com/triton-lang/llvm-project.git`
(Triton's fork), not mainline LLVM — a past session lost time to this.

**Two LLVM builds of one major version share a soname** (observed with LLVM 23; the v3.9.0 pin is LLVM 24 and the same holds). Every LLVM development build of a major version is
`libLLVM*.so.<major>.0git`, with no commit component — Feb- and Aug-2026 trees are both
`.so.23.0git`. The omniprobe plugins carry no RPATH/RUNPATH and bind to whatever LLVM the host
process mapped; `libtriton.so`'s RUNPATH points at its own tree, **but `LD_LIBRARY_PATH` is
searched before `DT_RUNPATH`** — measured: pointing it at the other tree silently swaps the LLVM
under a plugin compiled against a different one. `ldd`'s `=> not found` on a plugin is the bait:
never "fix" it by putting an LLVM lib dir on `LD_LIBRARY_PATH`.

## Leak scan gates every push (2026-11-08, `ba5c79b`, `e17ae35`)

The repo is public and must not gain hostnames. `scripts/leak-scan.sh` (copied from the AMP
framework) scans the tree and history and reads `scripts/leak-scan-baseline.txt`: an
owner-approved list of **accepted, already-published** findings (decision D1, `pm-decisions`),
keyed by path + SHA-256 of the matching line for tree findings, or commit sha + surface + path for
history findings — never by the matching text itself. `--print-baseline` emits candidate entries.

- Merge commits are diffed against their **first parent only** (`e17ae35`). `-m` (diff against
  every parent) produced false findings on merges of old branches.
- Gate a push on the scan's **exit code**, not on grepping its output.

## Open Questions

None.

## Last Verified

2026-04-27 (created by pm-restructure from architecture + instrumentation)
2026-10-26 (CI container layering, Triton pin facts for the v3.8.0 bump)
2026-10-27 (pin now v3.8.0; LLVM pin verification; two-stage image + cache checkpoint; fork-PR CI measured; branch protection; soname collision)
2026-11-08 (build-tree bitcode via copy_bitcode; leak-scan baseline and push gate; from session commits, not re-measured here; CI and Triton-pin sections untouched, still resting on 2026-10-27)
2026-11-08 (second session: Triton pin v3.9.0 section, triton_install.sh needs, llvm-config stale-cache fix; verified against ecb9a4c/8f49b37/5eba213/664c417/f48753c and the rf_triton-v3.9-bump artifacts, not re-built here; v3.8.0 history, CI and leak-scan sections not re-read)

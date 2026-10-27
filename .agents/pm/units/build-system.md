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
| `src/instrumentation/CMakeLists.txt` | Instrumentation plugin builds |

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
(v3.8.0 as of 2026-10-27), built with `containers/triton_install.sh`, and given as an absolute
path. Keep the local test environment's `TRITON_DIR` on the same tree: a suite run against a
Triton other than the pinned one passes green and proves the wrong thing.

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

## Triton pin: v3.8.0 (bumped 2026-10-26, `7f18d4b`)

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

**Two LLVM 23 builds share a soname.** Every LLVM development build of a major version is
`libLLVM*.so.<major>.0git`, with no commit component — Feb- and Aug-2026 trees are both
`.so.23.0git`. The omniprobe plugins carry no RPATH/RUNPATH and bind to whatever LLVM the host
process mapped; `libtriton.so`'s RUNPATH points at its own tree, **but `LD_LIBRARY_PATH` is
searched before `DT_RUNPATH`** — measured: pointing it at the other tree silently swaps the LLVM
under a plugin compiled against a different one. `ldd`'s `=> not found` on a plugin is the bait:
never "fix" it by putting an LLVM lib dir on `LD_LIBRARY_PATH`.

## Open Questions

None.

## Last Verified

2026-04-27 (created by pm-restructure from architecture + instrumentation)
2026-10-26 (CI container layering, Triton pin facts for the v3.8.0 bump)
2026-10-27 (pin now v3.8.0; LLVM pin verification; two-stage image + cache checkpoint; fork-PR CI measured; branch protection; soname collision)

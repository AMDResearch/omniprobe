# Dossier

## Metadata

- Workflow ID: rf_triton-v3.7-bump
- Workflow Type: refactor
- Lifecycle State: active
- Owner / Current Executor: unassigned
- Intended Write Scope:
  - `containers/toolchain.Dockerfile`
  - `containers/toolchain.def`
  - `containers/triton_install.sh` (only if patch function needs updating)
  - `docs/building-from-source.md`
  - `docs/triton-instrumentation.md`
  - `src/instrumentation/` (only if LLVM API changes require adaptation)
  - `tests/triton/` (only if Triton API changes break test kernels)
- Dependencies On Other Active Workflows:
  - rf_rename-logduration-to-omniprobe — broad write scope includes `containers/` and `.github/`.
    No functional conflict: that workflow renames symbols/env vars, this workflow changes version
    pins. Can proceed independently as long as both avoid editing the same lines. Coordinate at
    merge time if both are active simultaneously.

## Objective

Bump the pinned Triton version from v3.6.0 to v3.7.1 across CI containers, build scripts,
and documentation. Verify that omniprobe's instrumentation passes, source patches, and test
suite remain compatible with the new Triton release.

## Background / Context

The weekly `triton-staleness-check` CI job (`.github/workflows/triton-staleness-check.yml`)
detected that Triton released v3.7.0 (published 2026-05-07) while our CI pins v3.6.0. The
staleness check compares `ARG TRITON_VERSION=` in `containers/toolchain.Dockerfile` against
the GitHub API's latest release tag and fails when they differ.

Triton v3.7.0 includes multiple LLVM uprevs (with one reverted for stability), significant
AMD backend changes (gfx1250/RDNA4 focus, warp-pipeline, AsyncCopy), and some breaking API
changes (triton_kernels matmul refactor, make_block_ptr deprecation, Proton
GlobalScratchAllocOp replacement).

Triton v3.7.1 (published 2026-06-18) is a patch-only release on top of v3.7.0 with two
bugfixes and no API changes or LLVM uprev. The workflow target has been pivoted from v3.7.0
to v3.7.1 because the staleness check now fails against v3.7.1. All v3.7.0 investigation
findings (Steps 1-2) remain valid for v3.7.1.

## Contract

- All existing tests that pass before this refactor must continue to pass after.
- No change to user-visible behavior of omniprobe (CLI, interceptor, handlers, instrumentation).
- The `triton_install.sh` patch function must still successfully patch or gracefully skip the
  target assertion in Triton's AMD backend compiler.py.
- The instrumentation LLVM passes must compile and link against Triton v3.7.0's LLVM.

## Acceptance Criteria

- AC-1: `containers/toolchain.Dockerfile` pins `TRITON_VERSION=v3.7.1`.
- AC-2: `containers/toolchain.def` pins `TRITON_VERSION=v3.7.1`.
- AC-3: `docs/building-from-source.md` references v3.7.1.
- AC-4: `docs/triton-instrumentation.md` references v3.7.1.
- AC-5: `triton_install.sh` patch function works with v3.7.1 source tree (assertion is found
  and patched, or is confirmed absent/already removed and the function exits gracefully).
- AC-6: `cmake --build build` succeeds with Triton v3.7.1 LLVM headers (instrumentation
  passes compile cleanly).
- AC-7: Handler tests pass (25/25).
- AC-8: Triton integration tests pass (5/5) with `TRITON_DIR` pointing to a v3.7.1 install.
- AC-9: `triton-staleness-check` CI job passes (pinned version matches latest release, v3.7.1).
- AC-10: Stale v3.6.0 references in `triton_install.sh` examples updated to v3.7.1.

## Failure Policy

- If any existing test fails after a refactor step, investigate the root cause.
- If the failure is due to a Triton API change that requires non-trivial adaptation (>50 LOC),
  stop and report to the user before expanding scope.
- If LLVM API incompatibilities require changes to instrumentation passes, document the
  specific API breakage and proposed fix in handoff.md before proceeding.
- If the `triton_install.sh` patch target has moved or changed in a way that cannot be
  resolved by extending the existing search paths, stop and report.

## Scope

### Files to modify (certain)

| File | Change |
|------|--------|
| `containers/toolchain.Dockerfile` | `ARG TRITON_VERSION=v3.7.0` → `v3.7.1` |
| `containers/toolchain.def` | `TRITON_VERSION=v3.7.0` → `v3.7.1` |
| `docs/building-from-source.md` | Version reference in install command |
| `docs/triton-instrumentation.md` | Version reference in checkout command |

### Files to modify (conditional — only if compatibility issues arise)

| File | Condition |
|------|-----------|
| `containers/triton_install.sh` | Patch target moved or changed in v3.7.1; stale v3.6.0 examples |
| `src/instrumentation/*.cpp` | LLVM API surface changed |
| `tests/triton/*.py` | Triton Python API changed |

## Non-Goals

- Do not upgrade ROCm version (stays at 7.2.0).
- Do not adopt new Triton v3.7.0 features (gfx1250 support, warp-pipeline, etc.).
- Do not restructure the container build or CI pipeline.
- Do not fix pre-existing test failures (library filter chain test 2 hang, rocBLAS integration).

## Constraints and Assumptions

- Target GPU architecture remains gfx90a with sramecc+:xnack-.
- Local Triton install at `/home1/rvanoo/repos/triton` is currently v3.7.0 and will need
  rebuilding to v3.7.1 for local verification.
- The toolchain container rebuild (~3.5 hours on GitHub Actions) is triggered automatically
  when `containers/toolchain.Dockerfile` changes on main.
- Pre-existing test failures (from pm-current-state.md): library filter chain test 2 hangs;
  rocBLAS integration test broken. These are not caused by this refactor.

## Dependencies

- Triton v3.7.1 release (external, published 2026-06-18).
- No dependency on other active omniprobe workflows.
- Overlap note: rf_rename-logduration-to-omniprobe has `containers/` in its write scope but
  targets different content (symbol/env var names, not version pins).

## Plan Of Record

### Step 1: Verify patch compatibility (read-only investigation)

Clone or fetch Triton v3.7.1 source. Check whether `assert len(names) == 1` still exists
in `third_party/amd/backend/compiler.py` or `python/triton/backends/amd/compiler.py`.
Determine if the patch function in `triton_install.sh` needs updating.

### Step 2: Verify LLVM API compatibility (read-only investigation)

Compare LLVM headers between v3.6.0 and v3.7.1 Triton builds. Check that the LLVM APIs
used in `src/instrumentation/` are still present and have compatible signatures.

### Step 3: Rebuild local Triton install

Run `triton_install.sh --triton-version v3.7.1` to build Triton v3.7.1 locally. This
updates `/home1/rvanoo/repos/triton` and provides the new LLVM build directory.

### Step 4: Build omniprobe against new Triton LLVM

Run `cmake --build build` with `-DTRITON_LLVM` pointing to the v3.7.1 LLVM build. Fix any
compilation errors in instrumentation passes.

### Step 5: Run test suite

Run `./tests/run_all_tests.sh` with `TRITON_DIR` pointing to v3.7.1 install. Verify all
30 tests pass (25 handler + 5 Triton integration).

### Step 6: Bump version pins

Update the 4 files with hardcoded version references (AC-1 through AC-4).

### Step 7: Update triton_install.sh if needed

If Step 1 found patch compatibility issues, update the patch function (AC-5).
Clean up stale v3.6.0 references in examples (AC-10).

### Step 8: Final verification

Re-run tests to confirm the version-pinned files don't introduce regressions. Verify the
staleness check logic would pass with the new pin (AC-9).

## Verification Strategy

After each step, run the relevant verification:

| Step | Verification Command | Pass Criteria |
|------|---------------------|---------------|
| 3 | `triton_install.sh` exit code | Script completes without error |
| 4 | `cmake --build build` | Zero compilation errors |
| 5 | `./tests/run_all_tests.sh` | 30/30 pass (pre-existing failures excluded) |
| 6 | `grep TRITON_VERSION containers/toolchain.Dockerfile` | Shows `v3.7.1` |
| 8 | `./tests/run_all_tests.sh` | 30/30 pass |

## References

- Triton v3.7.0 release: https://github.com/triton-lang/triton/releases/tag/v3.7.0
- Triton v3.7.1 release: https://github.com/triton-lang/triton/releases/tag/v3.7.1
- Staleness check workflow: `.github/workflows/triton-staleness-check.yml`
- Toolchain image workflow: `.github/workflows/toolchain-image.yml`
- Triton install script: `containers/triton_install.sh`

## Open Questions

- Q1: Has the `assert len(names) == 1` assertion moved, changed, or been removed in v3.7.0?
  (Answered by Step 1.)
- Q2: Which specific LLVM APIs used by our instrumentation passes changed between Triton's
  LLVM versions? (Answered by Step 2.)
- Q3: Does the local Triton rebuild need to happen on a bare-metal node (GPFS) vs a VM node
  (virtiofs)? The build itself should be filesystem-agnostic, but test execution requires
  mmap-capable storage for `hipModuleLoad`.

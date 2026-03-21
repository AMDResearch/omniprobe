# Refactor: CI Setup

## Status
- [x] Done

## Objective

Update CI infrastructure to work with the rewritten `containers/triton_install.sh`
(completed in `rf_triton-install-script`), current ROCm (7.2), and current
Triton (v3.6.0). Build-only CI on `ubuntu-latest` (no GPU runner needed).
Two-tier container architecture with Ubuntu 24.04.

## Final State

### Container Architecture (two-tier)

| Image | Dockerfile | Rebuild frequency | Build time |
|-------|------------|-------------------|------------|
| `omniprobe-toolchain` | `containers/toolchain.Dockerfile` | Rare (ROCm/Triton version bumps) | ~4.5h (GHA) |
| `omniprobe` | `containers/omniprobe.Dockerfile` | Every code push | ~10min |

- Base image: `rocm/dev-ubuntu-24.04:7.2`
- `omniprobe.Dockerfile` uses `ARG TOOLCHAIN_IMAGE` / `FROM ${TOOLCHAIN_IMAGE}` (no hardcoded default)
- LLVM build inlined in `toolchain.Dockerfile` (no COPY dependency on local files)
- PEP 668 compatible (no system-level pip installs)

### Workflows

| Workflow | File | Triggers |
|----------|------|----------|
| Build Toolchain Image | `toolchain-image.yml` | push (narrow paths), workflow_dispatch |
| Build | `build.yml` | push, PR to main, workflow_dispatch |
| Triton Version Staleness Check | `triton-staleness-check.yml` | push (toolchain.Dockerfile), weekly cron, workflow_dispatch |

### Key Design Decisions

- **Secrets in workflows**: `secrets` context not available in `container.image` field; use explicit `docker pull` + `docker run`
- **GHA cache**: `type=gha,mode=max` with scope `toolchain-rocm${{ matrix.rocm-version }}`; only exports on fully successful builds
- **Staleness check**: Fails (exit 1) when pinned version differs from latest release
- **Matrix**: Single element (ROCm 7.2 only). RHEL deferred.

## Files (final)

### Added
- `containers/toolchain.Dockerfile` — expensive toolchain image
- `.github/workflows/toolchain-image.yml` — builds + pushes toolchain image
- `.github/workflows/build.yml` — builds omniprobe from toolchain image
- `.github/workflows/triton-staleness-check.yml` — weekly version check
- `.dockerignore` — Docker build context exclusions

### Modified
- `containers/omniprobe.Dockerfile` — rewritten to use toolchain as base
- `containers/omniprobe.def` — updated for ROCm 7.x + new triton_install.sh interface
- `containers/build.sh` — updated version defaults
- `containers/run.sh` — updated version defaults
- `containers/triton_install.sh` — added `--skip-llvm` flag, fixed pip caching
- `README.md` — updated CI badges

### Removed
- `.github/workflows/ubuntu.yml` — replaced by `build.yml`
- `.github/workflows/redhat.yml` — no RedHat container; deferred
- `.github/workflows/docker-upload.yml` — replaced by `toolchain-image.yml`
- `.github/workflows/build-triton-ubuntu.yml` — Triton built inside container
- `.github/workflows/build-triton-redhat.yml` — same

## Successor Refactors

- `rf_container-local` — clean up `.def`, `build.sh`, `run.sh` (deferred items from this refactor)

## Lessons Learned

- **GHA cache only saves on success**: BuildKit `type=gha` cache does not export layers
  from failed builds. This means iterating on CI is expensive when early layers (LLVM ~3.5h)
  succeed but later steps fail. Solution: checkpoint expensive builds as separate Docker
  layers with no COPY dependencies.
- **PEP 668 on Ubuntu 24.04**: System-level `pip install` is blocked. All pip work must
  happen inside venvs.
- **Apptainer uses `/bin/sh`**: `%post` sections run under dash, not bash. No `pipefail`.
  Use `set -eu` only.
- **Proxy bypass for container builds**: Use `env -u HTTP_PROXY -u HTTPS_PROXY` in
  subshells, never unset in the main shell.
- **Iterate locally first**: Local Apptainer builds with 128 cores (~25min) are much faster
  than GHA (~4.5h) for validating container changes.

## Progress Log

### Session 2026-03-19 (planning + Steps 1-5)
- Created dossier, completed Steps 1-5
- Key discovery: `rocm/dev-ubuntu-22.04` has ROCm pre-installed (no manual ROCm install needed)

### Session 2026-03-19 — 2026-03-20 (Step 6, CI iteration)
- 9 CI runs to get first green build
- Fixed: COPY context, .dockerignore location, cmake/ninja deps, python3-venv,
  pip msgpack caching, LLVM checkpoint architecture, PyTorch version detection,
  LICENSE exclusion, rocm-llvm-dev headers
- Validated locally via Apptainer to break the slow CI iteration loop

### Session 2026-03-20 (Step 7)
- Split Dockerfile into two tiers, switched to Ubuntu 24.04
- Caught PEP 668, Apptainer pipefail issue
- Both CI workflows green: toolchain (5h 4min) + build (10min 27s)
- Finalized triggers, merged to main

### Session 2026-03-21 (finalization)
- Squashed 38 commits into 1 clean commit (`fcabe12`)
- Updated README.md CI badges
- Staleness check changed to fail on version mismatch (`996dd8f`)
- Cleaned up branches (rf/ci-setup, backup-before-squash)
- Archived dossier to done/

## Last Verified
Commit: 996dd8f
Date: 2026-03-21

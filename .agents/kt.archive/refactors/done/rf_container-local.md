# Refactor: Container Local Scripts

## Status
- [x] Done (2026-04-07)

## Objective

Clean up the Apptainer definition file (`omniprobe.def`) and container helper
scripts (`build-container.sh`, `run-container.sh`) that are used for local
container builds, not CI. These are developer-facing tools for building and
running containers on local machines or clusters with Apptainer/Docker.

## Background

During the `rf_ci-setup` refactor, these files were partially updated to work
with the new `triton_install.sh` interface and ROCm 7.x, but they still had
stale content and naming issues. They were deferred from `rf_ci-setup` because
they don't affect CI workflows.

## Predecessor

- `rf_ci-setup` — CI refactor that updated the Dockerfile and workflows
- `rf_triton-install-script` — rewrote `triton_install.sh` (done)

## What Was Done

### Step 1: Two-stage Apptainer build (new `toolchain.def` + rewritten `omniprobe.def`)

Introduced a two-stage Apptainer build mirroring the Docker split:

- **`toolchain.def`** (new): `Bootstrap: docker` from `rocm/dev-ubuntu-24.04`.
  Installs packages, builds LLVM with shared libs, runs `triton_install.sh
  --skip-llvm`. Produces a toolchain `.sif` that is expensive and rarely rebuilt.
- **`omniprobe.def`** (rewritten): `Bootstrap: localimage` from toolchain SIF.
  Copies project, activates venv, pip installs requirements, cmake build+install.
  Cheap, rebuilt on code changes.

Issues fixed in the `.def` files:
- Base image updated from `rocm/dev-ubuntu-22.04` to `rocm/dev-ubuntu-24.04`
- Added `set -eu` to `%post` (no `pipefail` — Apptainer runs `/bin/sh`)
- Removed stale debug `ls` commands
- Fixed PEP 668: venv activation before pip install
- Updated label from "LOGDURATION" to "Omniprobe"
- Fixed install prefix: `/opt/logduration` → `/opt` (CMake installs into
  `<prefix>/omniprobe/`, so `/opt` yields `/opt/omniprobe/{bin,lib,...}`)
- Fixed runscript: don't fail if `/workspace` not bound
- Aligned env vars with Dockerfiles

Also fixed `omniprobe.Dockerfile` (same stale prefix + PEP 668 issue).

### Step 2: Renamed `build.sh` → `build-container.sh`

- Updated Apptainer build path for two-stage: builds toolchain SIF if missing,
  then omniprobe SIF via `Bootstrap: localimage`
- Fixed help text default from 6.3 to 7.2

### Step 3: Renamed `run.sh` → `run-container.sh`

- Removed "hiptimize" reference (old project name)
- Fixed help text default from 6.3 to 7.2
- Updated internal calls from `build.sh` to `build-container.sh`

### Step 4: Updated all references

- `README.md` (3 refs)
- `.dockerignore` root (2 refs) + `containers/.dockerignore` (2 refs)
- `.agents/kt/architecture.md` (1 ref)
- `.agents/kt/refactors/done/rf_ci-setup.md` (3 refs)

## Files Modified

- `containers/toolchain.def` — **new**, Apptainer equivalent of toolchain.Dockerfile
- `containers/omniprobe.def` — rewritten for two-stage build
- `containers/omniprobe.Dockerfile` — fixed stale prefix + PEP 668
- `containers/build.sh` → `containers/build-container.sh` — rename + two-stage
- `containers/run.sh` → `containers/run-container.sh` — rename + fixes
- `README.md`, `.dockerignore`, `containers/.dockerignore` — updated refs
- `.agents/kt/architecture.md`, `.agents/kt/refactors/done/rf_ci-setup.md` — updated refs

## Verification

- Structural diff of `.def` files vs Dockerfiles: all commands, packages, env vars,
  LLVM flags, cmake flags aligned (verified 2026-04-07)
- Full two-stage Apptainer build verified (2026-04-07):
  - `toolchain_0.1.0-rocm7.2.sif`: 18 GB, ~23 min build
  - `omniprobe_0.1.0-rocm7.2.sif`: 18 GB, ~6 min build (stage 2 only)

## Notes

- Apptainer `Bootstrap: localimage` is the equivalent of Docker's `FROM <local-image>`.
  The toolchain SIF acts as the cached base layer.
- Unlike Docker, Apptainer has no layer caching within a single `.def` — if `%post`
  fails partway through, the entire build restarts. The two-stage split mitigates this
  by isolating the expensive LLVM+Triton build in the toolchain SIF.
- `%environment` from a base SIF is available at runtime but NOT during a child's
  `%post`. The omniprobe.def re-exports all necessary vars at the top of `%post`.

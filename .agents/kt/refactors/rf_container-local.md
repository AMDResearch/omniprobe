# Refactor: Container Local Scripts

## Status
- [ ] In Progress
- [ ] Blocked
- [ ] Done

## Objective

Clean up the Apptainer definition file (`omniprobe.def`) and container helper
scripts (`build.sh`, `run.sh`) that are used for local container builds, not CI.
These are developer-facing tools for building and running containers on local
machines or clusters with Apptainer/Docker.

## Background

During the `rf_ci-setup` refactor, these files were partially updated to work
with the new `triton_install.sh` interface and ROCm 7.x, but they still have
stale content and naming issues. They were deferred from `rf_ci-setup` because
they don't affect CI workflows.

## Predecessor

- `rf_ci-setup` — CI refactor that updated the Dockerfile and workflows
- `rf_triton-install-script` — rewrote `triton_install.sh` (done)

## Implementation Steps

### Step 1: Clean up `containers/omniprobe.def`

The `.def` file has several issues:

1. **Stale debug `ls` commands**: Lines with `ls` commands that were added during
   debugging and should be removed
2. **Missing `set -e`**: The `%post` section doesn't fail on errors, so build
   failures are silently ignored. Add `set -eu` at the top of `%post`.
   Note: `pipefail` is NOT supported — Apptainer `%post` runs under `/bin/sh`
   (dash), not bash.
3. **PEP 668**: Ubuntu 24.04 enforces PEP 668 (externally managed environments).
   System-level `pip install` commands will fail. All pip work must happen inside
   a venv. The `triton_install.sh` script creates its own venv, but any direct
   `pip install` in `%post` (like `pip install -r requirements.txt`) must run
   after activating the venv (`. /app/triton/.venv/bin/activate`).
4. **Verify triton_install.sh invocation**: Should match the Dockerfile's invocation
   (`--triton-version v3.6.0`, `--skip-llvm` pattern, etc.)
5. **Verify ENV vars**: The `%environment` section should match the Dockerfile's
   ENV declarations (`TRITON_LLVM`, `ROCM_PATH`, `TRITON_HIP_LLD_PATH`)
5. **Base image**: Must be updated from `rocm/dev-ubuntu-22.04` to
   `rocm/dev-ubuntu-24.04` to match the Dockerfiles (changed in `rf_ci-setup`
   Step 7)

### Step 2: Rename and update `containers/build.sh`

Current issues:
- Name `build.sh` is generic. Rename to `build-container.sh`.
- Help text says `default: 6.3` — should be `7.2`
- Version array may be stale
- Should support both Docker and Apptainer build modes

### Step 3: Rename and update `containers/run.sh`

Current issues:
- Name `run.sh` is generic. Rename to `run-container.sh`.
- References "hiptimize" (old project name) in help text or comments
- `default: 6.3` — should be `7.2`
- Version array may be stale

### Step 4: Update references

After renames, update any references to the old filenames:
- Documentation (README.md, etc.)
- CI workflows (if any reference these scripts)
- Other scripts or Makefiles

## Files Modified

- `containers/omniprobe.def` — cleanup and alignment with Dockerfile
- `containers/build.sh` → `containers/build-container.sh` — rename + update
- `containers/run.sh` → `containers/run-container.sh` — rename + update

## Verification Gates

- `containers/build-container.sh --docker --rocm 7.2` builds successfully
- `containers/build-container.sh --apptainer --rocm 7.2` builds successfully
  (on a machine with Apptainer)
- `containers/run-container.sh` displays correct help text with updated defaults

## Dependencies

- ~~Wait for `rf_ci-setup` Step 7 to complete~~ **Done** (2026-03-21). Base image
  is `rocm/dev-ubuntu-24.04:7.2`, Dockerfile split is finalized. The `.def`
  file should mirror the final Dockerfile structure.

## Notes

- The `.def` file is the Apptainer equivalent of the Dockerfile. It uses the
  same base image and runs the same build steps, but with Apptainer-specific
  syntax (`%post`, `%environment`, `%labels`, etc.).
- On the development cluster: Apptainer 1.4.5 at `/usr/bin/apptainer`, 128 cores.
  No Docker available on the cluster.
- Proxy bypass needed for Apptainer builds on the cluster — see `rf_ci-setup.md`
  Practical Notes section.

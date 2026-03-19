# Refactor: CI Setup

## Status
- [x] TODO
- [ ] In Progress
- [ ] Blocked
- [ ] Done

## Objective

Update CI infrastructure to work with the rewritten `containers/triton_install.sh`
(completed in `rf_triton-install-script`), current ROCm (7.0/7.1/7.2), and current
Triton (v3.6.0). Build-only CI on `ubuntu-latest` (no GPU runner needed).
Container-based architecture.

## Problem Statement

CI is broken on multiple fronts:
- The `mi100` self-hosted runner (used by `ubuntu.yml` and `redhat.yml`) is offline
- ROCm versions hardcoded to `6.3`/`6.4` — current is 7.0/7.1/7.2
- Triton pinned to commit `368c864e9` — current is v3.6.0
- LLVM path hardcoded to `~/.triton/llvm/llvm-7ba6768d-ubuntu-x64` — the rewritten
  `triton_install.sh` builds LLVM into `${TRITON_REPO}/llvm-project/build/` instead
- `build-triton-ubuntu.yml` and `build-triton-redhat.yml` build Triton separately
  and pass LLVM as an artifact — this is no longer needed since `triton_install.sh`
  handles the full build inside the container
- Container files (`omniprobe.Dockerfile`, `omniprobe.def`) still invoke the old
  script interface (`source ... -g 368c864e9`)
- `omniprobe.def` has a bug at line 56: `pip install -r omniprobe/requirements.txt`
  should be `pip install -r requirements.txt` (already inside `/app/omniprobe`)
- Dockerfile has a typo: `TRITON_HIP_LDD_PATH` should be `TRITON_HIP_LLD_PATH`

## Source Material

- `.untracked/ci_update.md` — detailed CI analysis
- `.agents/kt/refactors/rf_triton-install-script.md` — predecessor refactor (done)
- Current workflow files in `.github/workflows/`
- Current container files in `containers/`

## Design Decisions

### Key decisions (already made with user)
- **Triton version**: Pin to v3.6.0 + add staleness check against latest release
- **Scope**: Build-only CI first; defer GPU test runner to a future refactor
- **Architecture**: Container-based (build image via Dockerfile, push to registry)
- **Runner**: `ubuntu-latest` for all jobs (no self-hosted `mi100` needed for builds)
- **LLVM path**: Deterministic `${TRITON_REPO}/llvm-project/build/` from new install script

### LLVM path change (from predecessor refactor)

The **old** CI approach:
- Triton's build process downloaded/built LLVM into `~/.triton/llvm/llvm-<hash>-ubuntu-x64/`
- CI tarballed `~/.triton/` and passed it as an artifact between jobs
- Dockerfiles hardcoded `ENV TRITON_LLVM=/root/.triton/llvm/llvm-7ba6768d-ubuntu-x64`
- Workflow matrices included `'$HOME/.triton/llvm/llvm-*'` with glob resolution

The **new** approach:
- `triton_install.sh` builds LLVM via `scripts/build-llvm-project.sh` into
  `${TRITON_REPO}/llvm-project/build/`
- Setting `LLVM_SYSPATH` during Triton install prevents Triton from downloading
  its own LLVM, so `~/.triton/llvm/` is NOT populated
- The path is deterministic (no glob patterns needed)
- Omniprobe builds with `-DTRITON_LLVM=${TRITON_REPO}/llvm-project/build`

### Triton install invocation change

Old: `bash -c "source /app/omniprobe/containers/triton_install.sh -g 368c864e9"`
New: `/app/omniprobe/containers/triton_install.sh --triton-version v3.6.0`

The script is now an executable (not sourced), and uses `--triton-version` instead of `-g`.

## Implementation Steps

### Step 1: Add `workflow_dispatch` and feature branch triggers

Small, safe prerequisite committed directly to main.

Changes:
- `ubuntu.yml`: Add `workflow_dispatch:` trigger (currently missing)
- `redhat.yml`: Add `workflow_dispatch:` trigger (currently missing)
- Both: Add feature branch to `push: branches:` for development iteration
- Both: Change `pull_request: branches:` filter from `main` to `ci-validated`
  (effectively disables PR triggers until CI is validated)

Note: `docker-upload.yml` already has `workflow_dispatch`.

### Step 2: Update container files

**`containers/omniprobe.Dockerfile`:**
- Line 2: `ARG ROCM_VERSION=6.3` → `ARG ROCM_VERSION=7.2`
- Line 5: Same default update
- Line 45: `bash -c "source /app/omniprobe/containers/triton_install.sh -g 368c864e9"`
  → `/app/omniprobe/containers/triton_install.sh --triton-version v3.6.0`
- Line 47: Fix typo `TRITON_HIP_LDD_PATH` → `TRITON_HIP_LLD_PATH`
- Line 48: `TRITON_LLVM=/root/.triton/llvm/llvm-7ba6768d-ubuntu-x64`
  → `TRITON_LLVM=/app/triton/llvm-project/build`
  (the install script clones Triton to `/app/triton` when run from `/app`)
- Line 60: Add `-DCMAKE_HIP_ARCHITECTURES=gfx90a` (or make it an ARG)
- Line 60: Ensure `TRITON_LLVM` uses absolute path (already will after line 48 fix)

**`containers/omniprobe.def`:**
- Line 5: `ROCM_VERSION=6.3` → `ROCM_VERSION=7.2`
- Line 15: `TRITON_LLVM=/root/.triton/llvm/llvm-7ba6768d-ubuntu-x64`
  → `TRITON_LLVM=/app/triton/llvm-project/build`
- Line 14: Fix typo `TRITON_HIP_LDD_PATH` → `TRITON_HIP_LLD_PATH`
- Lines 24-26: Same updates in `%post` section
- Line 51: `bash -c "source /app/omniprobe/containers/triton_install.sh -g 368c864e9"`
  → `/app/omniprobe/containers/triton_install.sh --triton-version v3.6.0`
- Line 56: Fix `pip install -r omniprobe/requirements.txt`
  → `pip install -r requirements.txt` (already cd'd into `/app/omniprobe` at line 55)

**`containers/build.sh`:**
- Line 14: `rocm_version="6.3"` → `rocm_version="7.2"`
- Line 17: `supported_rocm_versions=("6.3" "6.4")` → `supported_rocm_versions=("7.0" "7.1" "7.2")`

**`containers/run.sh`:**
- Line 16: `rocm_version="6.3"` → `rocm_version="7.2"`
- Line 19: `supported_rocm_versions=("6.3" "6.4")` → `supported_rocm_versions=("7.0" "7.1" "7.2")`

### Step 3: Update `docker-upload.yml`

- Line 21: ROCm matrix `['6.3', '6.4']` → `['7.0', '7.1', '7.2']`
- Runner stays `ubuntu-latest` (already correct)
- Build uses `containers/build.sh` which is updated in Step 2

### Step 4: Consolidate CI workflows

**Remove** (Triton is now built inside the container via `triton_install.sh`):
- `.github/workflows/build-triton-ubuntu.yml`
- `.github/workflows/build-triton-redhat.yml`

**Update `ubuntu.yml`:**
- Remove `check-llvm-install` job entirely (no more artifact-based LLVM sharing)
- Remove `trigger-llvm-build` job (no more separate Triton build workflow)
- Simplify `build` job:
  - Runner: `[mi100]` → `ubuntu-latest`
  - Remove `needs: [trigger-llvm-build, check-llvm-install]` and conditional `if:`
  - Matrix: Remove `llvm-install` dimension (only one LLVM path now)
  - Matrix: `rocm-version: ['6.3', '6.4']` → `['7.0', '7.1', '7.2']`
  - Remove Triton artifact download/unzip/resolve steps
  - Build inside the container image or replicate the container build inline
  - Set `TRITON_LLVM` to the deterministic path from `triton_install.sh`

**Update `redhat.yml`:**
- Same structural changes as `ubuntu.yml`
- Matrix: `rocm-version: ['6.3', '6.4']` → `['7.0', '7.1', '7.2']`
- Matrix: `os-release: ['9.4']` → update as appropriate

### Step 5: Add Triton version staleness check

New job step (in `ubuntu.yml` or as a separate lightweight workflow):
- Query `https://api.github.com/repos/triton-lang/triton/releases/latest`
- Compare against the pinned version (`v3.6.0`)
- Emit a GitHub Actions warning annotation on mismatch (does NOT fail the build)
- Runs on `ubuntu-latest`, no container needed

### Step 6: Validate single matrix element

Before enabling the full matrix:
- Build one config: Ubuntu 22.04 + ROCm 7.2 + Triton v3.6.0
- Use `gh workflow run --ref rf/ci-setup` to trigger from feature branch
- Verify container builds and omniprobe binary compiles successfully
- Check build artifacts are in the expected locations

### Step 7: Enable full matrix and re-enable PR triggers

- Remove feature branch from `push: branches:` triggers
- Change `pull_request: branches:` back to `main` (from `ci-validated`)
- Verify all matrix elements build successfully

## Practical Notes

### Feature branch CI iteration
- GitHub reads workflow files from the **pushed branch** for `push` events,
  so adding the feature branch name to `push: branches:` on the feature branch
  itself will trigger CI for pushes to that branch.
- `workflow_dispatch` requires the workflow to exist on the **default branch** (main);
  use `gh workflow run <name> --ref <branch>` to run the feature branch version
  after Step 1 is merged.

### Local tools
- `gh` installed at `~/.local/bin/gh`, needs `gh auth login` before use
- `git push` needed for CI iteration — user must grant per-session or
  push manually after review

## Files to Modify

- `containers/omniprobe.Dockerfile` — update Triton invocation, LLVM path, ROCm version
- `containers/omniprobe.def` — same updates + fix requirements.txt path bug
- `containers/build.sh` — update version array and default
- `containers/run.sh` — update version array and default
- `.github/workflows/docker-upload.yml` — update ROCm matrix
- `.github/workflows/ubuntu.yml` — consolidate, remove artifact logic, update matrix
- `.github/workflows/redhat.yml` — consolidate, remove artifact logic, update matrix

## Files to Remove

- `.github/workflows/build-triton-ubuntu.yml` — separate Triton build no longer needed
- `.github/workflows/build-triton-redhat.yml` — separate Triton build no longer needed

## Verification Gates

- **Step 1**: `workflow_dispatch` triggers appear in GitHub Actions UI
- **Step 2**: `containers/build.sh --docker --rocm 7.2` builds successfully (local or CI)
- **Step 3**: `docker-upload.yml` runs without errors on `workflow_dispatch`
- **Step 4**: `ubuntu.yml` and `redhat.yml` build omniprobe on `ubuntu-latest`
- **Step 5**: Staleness check emits annotation when pinned != latest
- **Step 6**: Single matrix element builds end-to-end
- **Step 7**: Full matrix green, PR triggers active

## Risk Assessment

- **ROCm repo URL changes**: ROCm 7.x may use different URL patterns for the
  `amdgpu-install` package. Verify against https://repo.radeon.com/amdgpu-install/
  during implementation.
- **Container base image**: `rocm/rocm-build-ubuntu-22.04` may not have tags for
  ROCm 7.x. May need to switch to a different base image or install ROCm from scratch.
- **Build time**: LLVM build inside the container on `ubuntu-latest` (2-core runner)
  will be slow (~45-90 min). Acceptable for CI but worth noting. Consider caching
  the container image via `docker-upload.yml` to avoid rebuilding LLVM on every push.
- **RedHat support**: RHEL container may need different package names for ROCm 7.x.
  The `yum`/`dnf` commands in `redhat.yml` may need adjustment.

## Rejected Approaches

- **Keep separate Triton build workflows**: The old approach built Triton/LLVM
  in a separate workflow and passed artifacts. This was needed because the old
  `triton_install.sh` was a source-only script that couldn't run standalone.
  Now that it's an executable with `--triton-version`, building inside the
  container is simpler and eliminates artifact management complexity.
- **Self-hosted runner for builds**: The `mi100` runner is offline and not needed
  for build-only CI. GPU runners should only be needed for runtime tests (deferred).

## Open Questions

- What container base image tags are available for ROCm 7.x? Need to check
  `rocm/rocm-build-ubuntu-22.04` tags on DockerHub.
- Should we add Ubuntu 24.04 support immediately or defer?

## Progress Log

### Session 2026-03-19
- Created refactor dossier from planning session

## Last Verified
Commit: n/a (dossier only, no code changes)
Date: 2026-03-19

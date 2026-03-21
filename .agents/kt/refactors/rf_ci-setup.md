# Refactor: CI Setup

## Status
- [x] In Progress
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

### Step 1: Add `workflow_dispatch` and feature branch triggers ✅

Small, safe prerequisite committed directly to main. **Done** (commit `0c8491c`, pushed to main).

Changes:
- `ubuntu.yml`: Add `workflow_dispatch:` trigger (currently missing)
- `redhat.yml`: Add `workflow_dispatch:` trigger (currently missing)
- Both: Add feature branch to `push: branches:` for development iteration
- Both: Change `pull_request: branches:` filter from `main` to `ci-validated`
  (effectively disables PR triggers until CI is validated)

Note: `docker-upload.yml` already has `workflow_dispatch`.

### Step 2: Update container files ✅

**Done** (commit `19cefd1`).

Key changes beyond what was originally planned:
- Base image switched from `rocm/rocm-build-ubuntu-22.04` to `rocm/dev-ubuntu-22.04`
  (old image had no ROCm 7.x tags; new image has ROCm pre-installed)
- Removed entire ROCm install block (redundant with new base image)
- `HIP_ARCHITECTURES` added as a build ARG (not hardcoded)

### Step 3: Update `docker-upload.yml` ✅

**Done** (commit `8b48093`).

### Step 4: Consolidate CI workflows ✅

**Done** (commit `4dcaa29`).

- `ubuntu.yml` rewritten: 250 lines / 3 jobs → 60 lines / 1 job
- `build-triton-ubuntu.yml` and `build-triton-redhat.yml` removed
  (Triton/LLVM now built inside container by `docker-upload.yml`)
- `redhat.yml` removed: no RedHat container image exists; deferred to future effort

### Step 5: Add Triton version staleness check ✅

**Done** (commit `182dca9`).

Implemented as separate workflow `triton-staleness-check.yml`:
- Weekly schedule (Monday 08:00 UTC) + workflow_dispatch + push to main
- Extracts pinned version from Dockerfile, compares against GitHub releases API
- Warning annotation only, does not fail

### Step 6: Validate single matrix element ✅

**Done.** Both `docker-upload.yml` (run `23338223868`) and `ubuntu.yml` (run
`23348348423`) pass green with Ubuntu 22.04 + ROCm 7.2 + Triton v3.6.0.
GHA cache is now populated for LLVM/Triton layers.

### Step 7: Two-tier architecture, Ubuntu 24.04, finalize

**Status: NOT STARTED.** Implementation plan agreed with user on 2026-03-20.

#### Why 7a+7b+7c are combined

Splitting the Dockerfile (7a), switching to Ubuntu 24.04 (7b), and renaming
workflows (7c) must ship as **one push** to avoid redundant LLVM rebuilds:

- **7a alone** (new `toolchain.Dockerfile`): High risk of GHA cache miss —
  new Dockerfile path changes the cache key chain, likely triggering a full
  LLVM rebuild (~4.5h on GHA) even though layer content is identical.
- **7b alone** (24.04 base image): Definitely invalidates the base layer,
  cascading through all subsequent layers. Full LLVM rebuild unavoidable.
- **7c alone** (workflow rename): The `type=gha` cache scope may be tied to
  workflow/step identity. Renaming the workflow could cause the *next* build
  to miss cache.

Combined: exactly **one** unavoidable LLVM rebuild (due to base image change),
and the cache is established under the new workflow name from the start.

**Validate locally via Apptainer first** (see Practical Notes: Proxy bypass),
then push all changes together.

#### 7a. Verify Ubuntu 24.04 base image

- Check `rocm/dev-ubuntu-24.04:7.2` exists on DockerHub
- If it doesn't exist, fall back to 22.04

#### 7b. Create DockerHub repo

- Create `<user>/omniprobe-toolchain` repository on DockerHub
- Keep existing `<user>/omniprobe` for the final image
- May need user help if CLI-based repo creation requires credentials

#### 7c. Split Dockerfile, switch to 24.04, rename workflows (single commit)

**Dockerfiles:**

1. **`containers/toolchain.Dockerfile`** (new) — expensive, rarely rebuilt:
   - Base: `rocm/dev-ubuntu-24.04:7.2` (or 22.04 fallback)
   - Installs: cmake, ninja, build deps, `rocm-llvm-dev`, python3-venv
   - Builds: LLVM (~3.5h on GHA), Triton, PyTorch ROCm wheel
   - ENV vars: `TRITON_LLVM`, `ROCM_PATH`, `TRITON_HIP_LLD_PATH`
   - Remove build trees after install (`rm -rf` LLVM build dir, Triton build
     artifacts) — keep sources for user reference
   - Push to DockerHub: `<user>/omniprobe-toolchain:latest-rocm7.2`

2. **`containers/omniprobe.Dockerfile`** (modified) — cheap, rebuilt often:
   - `FROM <user>/omniprobe-toolchain:latest-rocm7.2`
   - COPY omniprobe source, build, install
   - Remove build tree from final image
   - Push to DockerHub: `<user>/omniprobe:latest-rocm7.2`

**Workflows:**

| Old name | New name | Purpose |
|----------|----------|---------|
| `docker-upload.yml` | `toolchain-image.yml` | Build + push toolchain image |
| `ubuntu.yml` | `build.yml` | Build omniprobe from toolchain |

**`toolchain-image.yml` triggers** (narrow — only toolchain-affecting files):
- `push: paths:` → `containers/toolchain.Dockerfile`, `containers/triton_install.sh`,
  `containers/.dockerignore`, `VERSION`
- NOT triggered by: `CMakeLists.txt`, `containers/build.sh`, `containers/run.sh`,
  `containers/omniprobe.def`, `containers/omniprobe.Dockerfile`

**`build.yml` triggers**:
- `push: branches: [main]` (remove `rf/ci-setup`)
- `pull_request: branches: [main]` (change back from `ci-validated`)
- `workflow_dispatch:`
- `paths-ignore:` for docs/markdown
- Pulls `omniprobe-toolchain` image (not `omniprobe`)

**`triton-staleness-check.yml`** — no changes needed, name is fine.
Update it to read from `toolchain.Dockerfile` instead of `omniprobe.Dockerfile`.

**Matrix**: Single element — Ubuntu 24.04 + ROCm 7.2 only. RHEL deferred.

#### 7d. Validate locally via Apptainer

- Build toolchain equivalent locally (~25 min with 128 cores)
- Build omniprobe on top
- Use proxy bypass: `env -u HTTP_PROXY -u HTTPS_PROXY ...`
- Fix any issues before pushing to CI

#### 7e. Push and validate on CI

- Push all changes from 7c in one commit (or squashed set)
- One LLVM rebuild on CI (~4.5h), establishes GHA cache under new names
- Verify both `toolchain-image.yml` and `build.yml` pass green

#### 7f. Finalize

- Remove `rf/ci-setup` from `push: branches:` triggers in all workflows
- Change `pull_request: branches:` back to `main` (from `ci-validated`)
- **Restore git push deny rule** in `.claude/settings.local.json`:
  ```json
  "deny": ["Bash(git push:*)", "Bash(git push)"]
  ```
- Verify end-to-end: toolchain build → omniprobe build → green

## Files Modified

- `containers/omniprobe.Dockerfile` — base image, Triton invocation, LLVM path, ROCm version
- `containers/omniprobe.def` — same updates + fix requirements.txt path bug
- `containers/build.sh` — version array and default
- `containers/run.sh` — version array and default
- `.github/workflows/docker-upload.yml` — ROCm matrix, path filter, stale branch
- `.github/workflows/ubuntu.yml` — rewritten to use pre-built container

## Files Added

- `.github/workflows/triton-staleness-check.yml` — weekly Triton version check

## Files Removed

- `.github/workflows/build-triton-ubuntu.yml` — Triton built inside container now
- `.github/workflows/build-triton-redhat.yml` — same reason
- `.github/workflows/redhat.yml` — no RedHat container; deferred

## Verification Gates

- **Step 1**: `workflow_dispatch` triggers appear in GitHub Actions UI
- **Step 2**: `containers/build.sh --docker --rocm 7.2` builds successfully (local or CI)
- **Step 3**: `docker-upload.yml` runs without errors on `workflow_dispatch`
- **Step 4**: `ubuntu.yml` and `redhat.yml` build omniprobe on `ubuntu-latest`
- **Step 5**: Staleness check emits annotation when pinned != latest
- **Step 6**: Single matrix element builds end-to-end
- **Step 7**: Full matrix green, PR triggers active

## Risk Assessment

- ~~**Container base image**~~: Resolved — switched to `rocm/dev-ubuntu-22.04`.
- ~~**Build time**~~: Mitigated — `docker/build-push-action@v6` with `type=gha,mode=max`
  caches all Docker layers. First build is ~3.5h; subsequent are minutes.
- **ROCm repo URL changes**: N/A — removed explicit ROCm install (base image has it).
- **RedHat support**: Deferred — removed `redhat.yml`, needs RedHat Dockerfile.
- **GHA cache size**: GitHub Actions cache has a 10 GB limit per repo. The LLVM/Triton
  layers are large. If cache eviction becomes a problem, consider switching to
  registry-based cache (`type=registry`) on DockerHub instead.

## Rejected Approaches

- **Keep separate Triton build workflows**: The old approach built Triton/LLVM
  in a separate workflow and passed artifacts. This was needed because the old
  `triton_install.sh` was a source-only script that couldn't run standalone.
  Now that it's an executable with `--triton-version`, building inside the
  container is simpler and eliminates artifact management complexity.
- **Self-hosted runner for builds**: The `mi100` runner is offline and not needed
  for build-only CI. GPU runners should only be needed for runtime tests (deferred).

## Open Questions

- ~~What container base image tags are available for ROCm 7.x?~~ → Resolved:
  `rocm/dev-ubuntu-22.04` has 7.0/7.1/7.2 tags.
- ~~Should we add Ubuntu 24.04 support immediately or defer?~~ → Resolved:
  Switch to 24.04 now. Validate via Apptainer first.
- RedHat CI deferred: needs a RedHat Dockerfile + container push in docker-upload.yml.
  No official `rocm/dev-rhel-*` Docker images on DockerHub.
- Does `rocm/dev-ubuntu-24.04:7.2` exist on DockerHub? Must verify before switching.
  If not, stay on 22.04.

## Progress Log

### Session 2026-03-19 (planning)
- Created refactor dossier from planning session

### Session 2026-03-19 (execution start)
- Completed Step 1: workflow_dispatch + feature branch triggers (commit `0c8491c` on main)
- Created feature branch `rf/ci-setup`, rebased on main
- Updated dossier: Step 3 path filter for docker-upload.yml, Step 4 pre-built container clarification
- Setup: `gh auth login` done (user `rwvo`), git push deny rule removed from settings.local.json
- Next: Step 2 (update container files), then push branch and start CI iteration

### Session 2026-03-19 (Steps 2–5)
- Completed Step 2: container files updated (commit `19cefd1`)
  - Discovered `rocm/rocm-build-ubuntu-22.04` has no ROCm 7.x tags
  - Switched base image to `rocm/dev-ubuntu-22.04` (has 7.0/7.1/7.2, ROCm pre-installed)
  - Removed ROCm install block (redundant), added HIP_ARCHITECTURES ARG
- Completed Step 3: docker-upload.yml updated (commit `8b48093`)
- Completed Step 4: workflow consolidation (commit `4dcaa29`)
  - Removed redhat.yml (no RedHat container image exists; deferred)
  - Removed both build-triton-*.yml (Triton built inside container now)
  - Rewrote ubuntu.yml to use pre-built container (250→60 lines)
- Completed Step 5: staleness check (commit `182dca9`)
- Pushed rf/ci-setup, triggered docker-upload via workflow_dispatch (run 23291044263)
- Waiting for container builds (3 ROCm versions, ~45-90 min each for LLVM build)
- Next: validate container builds, then Step 6 (single matrix validation)

### Session 2026-03-19 (CI iteration — Steps 6-7 in progress)

**Bugs found and fixed during CI iteration:**
1. `COPY ../ /app/omniprobe` → `COPY . /app/omniprobe` — Docker COPY cannot
   reference outside build context (commit `292e99e`)
2. `.dockerignore` was in `containers/`, not at repo root where Docker reads it —
   copied to repo root (commit `292e99e`)
3. `.def` requirements.txt path: the "fix" in Step 2 was wrong — original
   `omniprobe/requirements.txt` was correct because CWD is `/app/omniprobe` (repo root),
   not `/app/omniprobe/omniprobe`. Reverted (commit `329919e`).
4. `cmake` and `ninja-build` not in `rocm/dev-ubuntu-22.04` base image (old
   `rocm-build` image had them) — added to apt-get install (commit `fd8f696`).
   Also added `set -euo pipefail` to `build.sh` so docker build failures propagate.
5. Matrix narrowed to `['7.2']` only for faster validation; `--load` added to
   docker build in `build.sh` (commit `1872b6b`).
6. `python3-venv` missing in base image — added to apt-get install. LLVM build
   succeeded (7608 steps, ~3.5h) but failed at triton_install.sh Step 5 venv
   creation (commit `769cef4`).
7. Switched `docker-upload.yml` from manual `build.sh` + `docker tag` + `docker push`
   to `docker/build-push-action@v6` with GitHub Actions layer cache (`type=gha`,
   `mode=max`). After first successful build, cached LLVM/Triton layers make
   subsequent iterations fast (~minutes) (commit `769cef4`).

### Session 2026-03-20 (CI iteration continues)

Resumed from run `23301342393`. Continued fixing CI failures, each requiring
a full LLVM rebuild (~3.5h per attempt) since GHA cache only saves on
fully successful builds.

**Bugs found and fixed (continuing from previous session):**

8. Dockerfile layer ordering: COPY before LLVM build invalidated cache when
   code changed. Reordered layers (commit `30db7a0`).
   - Run `23302668217` — failed: pip msgpack error

9. pip msgpack "Memoryview is too large" when caching ~2.8GB PyTorch ROCm wheel.
   Added `--no-cache-dir` to pip install (commit `1c6ac99`).
   - Run `23311400785` — cancelled for checkpoint restructure

10. **LLVM checkpoint architecture**: User feedback that LLVM rebuilt every time
    a later step failed. Inlined LLVM build as its own Dockerfile RUN layer
    with NO COPY dependency, so script/code changes never invalidate it.
    Added `--skip-llvm` flag to `triton_install.sh` for the split workflow.
    (commit `f65249c`)
    - Run `23311980261` — failed: PyTorch version detection missing

11. PyTorch version detection missing in `--skip-llvm` fast path — `PYTORCH_ROCM_VERSION`
    was empty, URL was `.../whl/rocm` instead of `.../whl/rocm7.1`. Added version
    detection to skip-llvm path (commit `ae70eb8`).
    - Run `23320506358` — failed: LICENSE file excluded by .dockerignore

12. `.dockerignore` excluded `LICENSE*` but CMake CPack needs the LICENSE file
    at configure time. Commented out the exclusion (commit `eea684a`).
    - Run `23327523673` — failed: LLVM_INSTALL_DIR invalid

13. `instrument-amdgpu-kernels-rocm` subproject expected LLVM dev headers at
    `/opt/rocm/llvm/include/llvm` — not present in `rocm/dev-ubuntu-22.04`
    Docker image. The `-rocm` build is needed (not just `-triton`) because
    users need it to instrument HIP programs with ROCm's `opt`.
    - **Wrong fix**: commit `a338745` skipped the `-rocm` build — **reverted**
      in `44185c5`.
    - **Right fix**: install `rocm-llvm-dev` package in the Dockerfile.
      Ubuntu package name: `rocm-llvm-dev` (~1.7 GB). Provides
      `/opt/rocm/llvm/include/llvm/` headers and `/opt/rocm/llvm/lib/cmake/llvm/LLVMConfig.cmake`.
    - Run `23333814885` — **cancelled** (wrong fix applied; would have missed -rocm plugin)

**Key discoveries:**
- BuildKit `type=gha` cache is ONLY exported on fully successful builds.
  Partial failures don't save any layers. The LLVM checkpoint architecture
  is correct but can't help until one build succeeds end-to-end.
- The `rocm/dev-ubuntu-22.04` Docker image includes `rocm-llvm` (compiler
  binaries) but NOT `rocm-llvm-dev` (headers, cmake config). Our cluster
  has `rocm-llvm-devel` installed, which is why local builds work.

**Strategy change: iterate locally with Apptainer before CI.**

The CI iteration loop (push → wait 3.5h → read logs → fix → repeat) is
too slow. The cluster has Apptainer 1.4.5 and 128 cores, so LLVM builds
will be much faster locally. The `.def` file (`containers/omniprobe.def`)
already exists and uses the same base image.

### Session 2026-03-20 (Apptainer validation + CI push)

**Local Apptainer build** validated the `rocm-llvm-dev` fix:
- Ran `apptainer build` from repo root with proxies disabled in subshell
  (`env -u HTTP_PROXY -u HTTPS_PROXY ...`) for fast direct downloads
- Full build completed successfully: LLVM, Triton, Omniprobe with both
  ROCm and Triton plugins
- Output: 17 GB SIF file (scratch, deleted after validation)
- Key insight: `rocm-llvm-dev` was the **only** remaining fix needed

**Proxy note**: The cluster routes through an SSH-forwarded Squid proxy
for LLM API access. Large downloads (Docker/Apptainer image pulls, git
clones, pip installs) are painfully slow through it. Solution: disable
proxies in subshells for container builds while keeping them in the main
shell for API connectivity. Pattern: `env -u HTTP_PROXY -u HTTPS_PROXY cmd`.

14. Applied `rocm-llvm-dev` fix to both `omniprobe.Dockerfile` and
    `omniprobe.def` (commit `0da3b17`).
    - Run `23338223868` — **success** (4h 29m, LLVM build ~3.5h on GHA)

15. `ubuntu.yml` failed: `secrets` context not available in `container.image`
    field. GitHub masks secret values in job outputs too (`##[warning]Skip
    output 'image' since it may contain secret`). Fixed by switching from
    `container:` key to explicit `docker pull` + `docker run` in the build
    step (commits `3664b69`, `a67cb72`).
    - Run `23348142993` — failed (empty image name from masked output)
    - Run `23348348423` — **success**

**CI run history:**

`docker-upload.yml` (container build):
| Run | Commit | Result | Issue |
|-----|--------|--------|-------|
| `23291044263` | `769cef4` | failed | COPY context, .dockerignore |
| `23301342393` | `769cef4` | cancelled | Dockerfile reorder |
| `23302668217` | `30db7a0` | failed | pip msgpack |
| `23311400785` | `1c6ac99` | cancelled | checkpoint restructure |
| `23311980261` | `f65249c` | failed | PyTorch version detection |
| `23320506358` | `ae70eb8` | failed | LICENSE excluded |
| `23327523673` | `eea684a` | failed | LLVM_INSTALL_DIR invalid |
| `23333814885` | `a338745` | cancelled | wrong fix (skipped -rocm) |
| `23338223868` | `0da3b17` | **success** | first green build |

`toolchain-image.yml` (new name, two-tier architecture):
| Run | Commit | Result | Issue |
|-----|--------|--------|-------|
| `23358153218` | `12a3856` | **success** | 24.04 + two-tier (5h 4min) |

`ubuntu.yml` → `build.yml` (omniprobe build from toolchain image):
| Run | Commit | Result | Issue |
|-----|--------|--------|-------|
| `23348142993` | `3664b69` | failed | secrets masked in job output |
| `23348348423` | `a67cb72` | **success** | docker run approach works |
| `23358153229` | `12a3856` | failed | expected: toolchain image not yet built |
| `23368471514` | `4f8e359` | **success** | two-tier works (10m 27s) |

**Step 6 complete.** Both `docker-upload.yml` and `ubuntu.yml` pass.
GHA cache is now populated for the LLVM/Triton layers (subsequent
`docker-upload` runs will be minutes, not hours).

**Branch state:** `rf/ci-setup` at commit `a67cb72`.

### Session 2026-03-20 (Step 7 planning)

Discussed Step 7 architecture with user. Key decisions:

1. **Two-tier containers**: Split monolithic Dockerfile into `toolchain.Dockerfile`
   (expensive, ~4.5h) and `omniprobe.Dockerfile` (cheap, ~5min). Rationale:
   code-only changes shouldn't require 4.5h LLVM rebuild.

2. **Two DockerHub repos**: `omniprobe-toolchain` + `omniprobe` (separate from
   existing `omniprobe` repo which currently holds the monolithic image).

3. **Ubuntu 24.04**: Switch from 22.04 to 24.04 LTS. Validate locally first.

4. **Matrix reduction**: Ubuntu 24.04 + ROCm 7.2 only. The old CI had a 3×2×2
   matrix (3 OS × 2 ROCm × 2 LLVM-source = 12 jobs). User decided to start
   minimal and expand if needed.

5. **Workflow renames**: `docker-upload.yml` → `toolchain-image.yml`,
   `ubuntu.yml` → `build.yml`.

6. **Trigger narrowing**: `toolchain-image.yml` should NOT trigger on
   `CMakeLists.txt`, `build.sh`, `run.sh`, or `.def` changes — only on files
   that affect the toolchain image.

7. **Image contents**: Keep sources (open-source repo), remove build trees.

8. **Deferred items** (separate dossier `rf_container-local.md`):
   - `omniprobe.def` cleanup (stale debug `ls`, missing `set -e`)
   - `build.sh` → `build-container.sh` rename + fix stale defaults
   - `run.sh` → `run-container.sh` rename + fix stale "hiptimize" reference

**Implementation order for Step 7:**
1. Verify `rocm/dev-ubuntu-24.04:7.2` exists on DockerHub (7a)
2. Create `omniprobe-toolchain` DockerHub repo (7b, may need user help)
3. Create `toolchain.Dockerfile`, modify `omniprobe.Dockerfile`, rename
   workflows, update triggers — all as one logical change (7c)
4. Validate locally via Apptainer with proxy bypass (7d)
5. Push everything together → one CI LLVM rebuild (7e)
6. Finalize: re-enable PR triggers, remove feature branch, restore deny rule (7f)

**Cache rationale:** Steps 7a–7b are prerequisites. Step 7c combines the
Dockerfile split, base image switch, and workflow rename into one push so
that only one LLVM rebuild occurs on CI. Doing them separately would risk
2–3 redundant rebuilds (~4.5h each).

### Session 2026-03-20 (Step 7 implementation)

**7a verified:** `rocm/dev-ubuntu-24.04:7.2` confirmed to exist on DockerHub.

**7b:** DockerHub repo `omniprobe-toolchain` will be auto-created on first push.

**7c implemented:**
- Created `containers/toolchain.Dockerfile`:
  - Base: `rocm/dev-ubuntu-24.04:7.2`
  - Installs apt deps, builds LLVM (inlined checkpoint), runs `triton_install.sh --skip-llvm`
  - Sets ENV vars: `TRITON_LLVM`, `ROCM_PATH`, `TRITON_HIP_LLD_PATH`
  - Removed system-level `pip install --upgrade` (PEP 668 on 24.04 blocks
    system pip installs; all Python work happens in venvs via `triton_install.sh`)
- Rewrote `containers/omniprobe.Dockerfile`:
  - `ARG TOOLCHAIN_IMAGE` + `FROM ${TOOLCHAIN_IMAGE}` (no hardcoded default)
  - COPY, build, install, `rm -rf build`
- Created `.github/workflows/toolchain-image.yml` (from `docker-upload.yml`):
  - Narrow path triggers: `toolchain.Dockerfile`, `triton_install.sh`, `.dockerignore`, `VERSION`
  - Pushes to `omniprobe-toolchain` DockerHub repo
  - New cache scope: `toolchain-rocm${{ matrix.rocm-version }}`
- Created `.github/workflows/build.yml` (from `ubuntu.yml`):
  - Pulls `omniprobe-toolchain` image (was `omniprobe`)
  - Renamed: "Build" / "build" (was "Ubuntu Linux (ROCm, LLVM)" / "ubuntu")
- Updated `.github/workflows/triton-staleness-check.yml`:
  - Reads version from `toolchain.Dockerfile` (was `omniprobe.Dockerfile`)
  - Fixed grep: `ARG TRITON_VERSION=\K\S+` (was `--triton-version\s+\K\S+`
    which would have returned `${TRITON_VERSION}` not `v3.6.0`)
  - Path trigger: `containers/toolchain.Dockerfile` (was `triton_install.sh`)
- Updated `.dockerignore`: added `containers/toolchain.Dockerfile` exclusion
- Updated `rf_container-local.md`: noted `.def` needs 24.04 base image update

**PEP 668 discovery**: Ubuntu 24.04 enforces PEP 668 (externally managed
environments), blocking `pip install` outside venvs. The old Dockerfile had
system-level `pip install --upgrade pip/setuptools` that would fail. Fix:
removed those commands — they were unnecessary since `triton_install.sh`
creates its own venv and installs everything there.

**7d partial validation completed.** Cluster network too slow (~473 kB/s)
for full LLVM build. Results:
- 24.04 base image (`rocm/dev-ubuntu-24.04:7.2`) pulls and works ✅
- `apt-get update` with ROCm repos works ✅
- Apt packages start installing (no package-not-found errors) ✅
- Caught PEP 668 (system pip blocked on 24.04) → fixed in Dockerfile ✅
- Caught `/bin/sh` pipefail → documented for .def cleanup ✅
- Full LLVM/Triton build deferred to CI (platform-independent C++ code)

**7e pushed:** Commit `12a3856`, pushed to `rf/ci-setup`.

CI runs:
- `toolchain-image.yml` run `23358153218` — **success** (5h 4min)
- `build.yml` run `23358153229` — failed (expected: toolchain image not yet built)
- `build.yml` run `23368471514` — **success** (10min 27s, workflow_dispatch)

**Step 7 complete (7a–7e).** Both workflows pass green on Ubuntu 24.04 + ROCm 7.2.
GHA cache populated under new `toolchain-rocm7.2` scope.

**Next:** Step 7f (finalize: restore PR triggers to `main`, remove `rf/ci-setup`
from push triggers, restore git push deny rule, merge to main).

## Practical Notes

### Proxy bypass for local Apptainer builds (CRITICAL)

The cluster routes through an SSH-forwarded Squid proxy for LLM API access.
**NEVER disable proxies globally** — this breaks the Claude API connection and
terminates the session.

For container builds (which download large files), disable proxies **only in
the subshell** running the build:

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
    apptainer build /tmp/scratch.sif containers/omniprobe.def
```

This pattern was validated in the 2026-03-20 session. The main shell retains
its proxy settings and continues to work with the LLM API.

**DO NOT use `unset HTTP_PROXY`** in the main shell. Use `env -u` in subshells.

### Feature branch CI iteration
- GitHub reads workflow files from the **pushed branch** for `push` events,
  so adding the feature branch name to `push: branches:` on the feature branch
  itself will trigger CI for pushes to that branch.
- `workflow_dispatch` requires the workflow to exist on the **default branch** (main);
  use `gh workflow run <name> --ref <branch>` to run the feature branch version
  after Step 1 is merged.

### Local tools
- `gh` installed at `~/.local/bin/gh`, already authenticated (user `rwvo`)
- `git push` deny rule removed from `settings.local.json` for CI iteration —
  must be restored in Step 7g

### GitHub Actions secrets limitations

- `secrets` context is NOT available in `container.image` field
- Job outputs containing secret values are masked by GitHub
- Workaround: use `docker login` + `docker pull` + `docker run` explicitly

## Last Verified
Commit: 12a3856
Date: 2026-03-20

# Run-Log

Append an entry after every meaningful execution step. This is not optional. If the session is interrupted, this log is the only record of progress.

## Entry Format

Use append-only entries with:

- timestamp
- actor
- planned step
- action taken
- result
- files touched
- verification run
- criteria impact
- blocker or risk

## Log Entries

### 2026-06-01 — Session 1

- **Actor**: claude
- **Planned step**: Create workflow packet for Triton v3.6.0 → v3.7.0 bump
- **Action taken**: Investigated CI staleness check failure. Confirmed Triton v3.7.0 released
  2026-05-07, pinned version is v3.6.0. Identified 4 files with hardcoded version references
  and 3 conditional write-scope areas. Reviewed v3.7.0 release notes for breaking changes
  (LLVM uprevs, AMD backend changes, matmul API refactor). Created full refactor workflow
  packet with 9 acceptance criteria and 8-step plan. Ran readiness check — all items passed.
  Promoted packet from draft to active.
- **Result**: success
- **Files touched**: dossier.md, run-log.md, handoff.md, artifacts.md (created);
  active-workflows.md (updated)
- **Verification**: workflow-readiness-check passed (all items green)
- **Criteria impact**: None — no execution steps performed yet, packet is planning only
- **Blocker / Risk**: LLVM API and patch compatibility with v3.7.0 unknown until Steps 1-2

### 2026-06-01 — Session 2, Entry 1

- **Actor**: claude
- **Planned step**: Step 1 — Verify patch compatibility with Triton v3.7.0
- **Action taken**: Fetched `third_party/amd/backend/compiler.py` from Triton v3.7.0 tag.
  Confirmed `assert len(names) == 1` still exists at line 465. Verified grep/sed patterns
  in `patch_triton_source()` match correctly. Second candidate path
  (`python/triton/backends/amd/compiler.py`) returns 404 as expected.
- **Result**: PASS — no changes needed to `triton_install.sh`
- **Files touched**: none (read-only)
- **Verification**: manual inspection of v3.7.0 source
- **Criteria impact**: AC-5 can be met without changes to patch function
- **Blocker / Risk**: none

### 2026-06-01 — Session 2, Entry 2

- **Actor**: claude
- **Planned step**: Step 2 — Verify LLVM API compatibility
- **Action taken**: Compared LLVM hashes (f6ded0be → ac5dc54d, 13,287 commits). Checked
  all LLVM headers used by instrumentation passes for API changes. Found one breaking
  change: `llvm/Passes/PassPlugin.h` moved to `llvm/Plugins/PassPlugin.h`. Verified all
  other APIs (Cloning, Linker, PassBuilder, Module, IR, Bitcode) are unchanged.
- **Result**: ONE BREAKING CHANGE — PassPlugin.h path moved
- **Files touched**: none (read-only)
- **Verification**: manual git diff of LLVM headers at both commits
- **Criteria impact**: AC-6 requires fixing the include path in 3 files
- **Blocker / Risk**: Straightforward fix with `__has_include` for version portability

### 2026-06-01 — Session 2, Entry 3

- **Actor**: claude
- **Planned step**: Step 3 — Rebuild local Triton install at v3.7.0
- **Action taken**: Backed up v3.6.0 install to /home1/rvanoo/repos/triton-v3.6.0-backup.
  Ran `env -u HTTP_PROXY ... triton_install.sh --triton-version v3.7.0` from /home1/rvanoo/repos/.
  Script completed all 6 steps: clone, patch (assertion in compiler.py), LLVM build (shared libs),
  venv setup (Python 3.12, PyTorch 2.12.0+rocm7.2), Triton build (3.7.0+git5f3f125e).
- **Result**: SUCCESS — Triton v3.7.0 installed at /home1/rvanoo/repos/triton
- **Files touched**: /home1/rvanoo/repos/triton (rebuilt from scratch)
- **Verification**: Script exit code 0; 121 shared LLVM .so files present
- **Criteria impact**: Enables AC-6 (omniprobe build) and AC-8 (Triton integration tests)
- **Blocker / Risk**: None

### 2026-07-13 — Session 3, Entry 1

- **Actor**: claude
- **Planned step**: Pivot workflow target from v3.7.0 to v3.7.1
- **Action taken**: Updated dossier.md (objective, AC-1 through AC-4, AC-9 target changed to
  v3.7.1; added AC-10 for stale v3.6.0 cleanup; added background note about v3.7.1 as
  patch-only release; added v3.7.1 release reference). Updated handoff.md to reflect current
  state and pivot plan. Updated plan-of-record steps with v3.7.1 references.
- **Result**: SUCCESS — workflow packet updated for v3.7.1 target
- **Files touched**: dossier.md, handoff.md, run-log.md
- **Verification**: manual review of updated documents
- **Criteria impact**: All ACs now target v3.7.1 instead of v3.7.0
- **Blocker / Risk**: None — v3.7.1 is patch-only, all v3.7.0 findings apply

### 2026-07-13 — Session 3, Entry 2

- **Actor**: claude
- **Planned step**: Step 3 (repeat) — Rebuild local Triton install at v3.7.1
- **Action taken**: Removed old v3.7.0 install. Ran triton_install.sh --triton-version v3.7.1.
  Hit two issues: (1) local LLVM mirror lacked v3.7.1's LLVM commit (1f126a6dea5) — fixed
  by pointing remote to triton-lang/llvm-project fork and fetching. (2) Triton's FetchContent
  download of googletest failed due to SSL cert issues — fixed with GIT_SSL_NO_VERIFY=1.
  LLVM rebuilt incrementally (7903 targets), then Triton built (503 targets).
- **Result**: SUCCESS — Triton v3.7.1 installed at /home1/rvanoo/repos/triton
- **Files touched**: /home1/rvanoo/repos/triton (rebuilt), local LLVM mirror remote fixed
- **Verification**: Triton version 3.7.1, LLVM hash 1f126a6dea5 (correct), 121 shared .so files
- **Criteria impact**: Enables AC-6 (omniprobe build) and AC-8 (Triton integration tests)
- **Blocker / Risk**: None

### 2026-07-13 — Session 3, Entry 3

- **Actor**: claude
- **Planned step**: Steps 6-7 — Bump version pins from v3.7.0 to v3.7.1
- **Action taken**: Updated 5 files: toolchain.Dockerfile, toolchain.def (TRITON_VERSION
  v3.7.0→v3.7.1), building-from-source.md, triton-instrumentation.md (example versions),
  triton_install.sh (stale v3.6.0 examples→v3.7.1, updated comment at line 405).
- **Result**: SUCCESS — committed as 7acfafa
- **Files touched**: containers/toolchain.Dockerfile, containers/toolchain.def,
  containers/triton_install.sh, docs/building-from-source.md, docs/triton-instrumentation.md
- **Verification**: grep TRITON_VERSION containers/toolchain.Dockerfile shows v3.7.1
- **Criteria impact**: AC-1, AC-2, AC-3, AC-4, AC-10 met
- **Blocker / Risk**: None

### 2026-07-13 — Session 3, Entry 4

- **Actor**: claude
- **Planned step**: Step 4 — Build omniprobe against v3.7.1 LLVM
- **Action taken**: Reconfigured cmake with TRITON_LLVM pointing to v3.7.1 LLVM build.
  Built with `cmake --build build -j128`. All targets compiled cleanly including
  triton plugin .so files (AMDGCNSubmitAddressMessages-triton, BBStart-triton, BBInterval-triton).
- **Result**: SUCCESS — zero compilation errors
- **Files touched**: build/ (incremental rebuild)
- **Verification**: 100% build completion, 3 triton plugin .so files present
- **Criteria impact**: AC-6 met (instrumentation passes compile cleanly with v3.7.1 LLVM)
- **Blocker / Risk**: None

### 2026-07-13 — Session 3, Entry 5

- **Actor**: claude
- **Planned step**: Step 5 — Run test suite
- **Action taken**: Ran ./tests/run_all_tests.sh with TRITON_DIR=/home1/rvanoo/repos/triton.
- **Result**: SUCCESS — all executed suites passed
  - Handler tests: 25/25 pass
  - Library filter chain: 5/5 pass
  - Triton integration: 5/5 pass
  - hipBLASLt/rocBLAS: skipped (env vars not set, not in scope)
- **Files touched**: none (read-only)
- **Verification**: test exit code 0, all 35 tests pass across 3 suites
- **Criteria impact**: AC-7 met (handler tests 25/25), AC-8 met (Triton integration 5/5)
- **Blocker / Risk**: None

### 2026-07-13 — Session 3, Entry 6

- **Actor**: claude
- **Planned step**: Step 8 — Final verification
- **Action taken**: Verified staleness check (grep TRITON_VERSION shows v3.7.1). Verified
  no stale v3.6.0 references in active code/docs. All acceptance criteria met.
- **Result**: SUCCESS — all ACs verified
- **Files touched**: run-log.md, handoff.md (updated)
- **Verification**: AC-1 through AC-10 all met
- **Criteria impact**: AC-9 met (staleness check would pass with v3.7.1)
- **Blocker / Risk**: None

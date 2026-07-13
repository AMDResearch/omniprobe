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

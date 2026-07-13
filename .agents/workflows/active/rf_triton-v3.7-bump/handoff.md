# Handoff

## Current Status

Steps 1-2 complete (read-only investigation). Both patch compatibility and LLVM API
compatibility verified. One breaking LLVM change identified and mitigation planned.
Proceeding to Step 3 (Triton rebuild).

## Last Verified

Steps 1-2 verified 2026-06-01.

## Next Exact Step

Step 3 IN PROGRESS: Triton v3.7.0 rebuild running at /home1/rvanoo/repos/triton.
Old v3.6.0 install backed up to /home1/rvanoo/repos/triton-v3.6.0-backup.
Build launched via `env -u HTTP_PROXY ... triton_install.sh --triton-version v3.7.0`.
Currently at LLVM build phase (30-90 min). After completion:
Step 4: Build omniprobe with `cmake --build build`.
Step 5: Run test suite.

## Active Risks / Blockers

- Local Triton rebuild (~1-2 hours) in progress.
- Test execution requires bare-metal node (confirmed: currently on bare-metal).

## Investigation Findings

### Step 1: Patch Compatibility (PASS)
- `assert len(names) == 1` still exists at `third_party/amd/backend/compiler.py` line 465.
- `patch_triton_source()` will find and patch it correctly. No changes needed.

### Step 2: LLVM API Compatibility (ONE BREAKING CHANGE)
- LLVM hash: f6ded0be → ac5dc54d (13,287 commits apart).
- `llvm/Passes/PassPlugin.h` was **moved** to `llvm/Plugins/PassPlugin.h`.
- All 3 instrumentation pass files include the old path.
- **Fix**: Use `#if __has_include("llvm/Plugins/PassPlugin.h")` to support both LLVM versions.
- All other APIs used (Cloning, Linker, PassBuilder, Module, IR) are unchanged.

## Required Reads Before Resuming

- This handoff
- `dossier.md` in this packet (for full plan and acceptance criteria)
- `containers/triton_install.sh` lines 146-173 (patch function)
- `src/instrumentation/` (LLVM pass source files)

## Proposed Spec Changes

None.

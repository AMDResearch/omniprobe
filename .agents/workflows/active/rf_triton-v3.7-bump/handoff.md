# Handoff

## Current Status

Steps 1-3 complete (investigation + Triton v3.7.0 rebuild). Pivoting target from v3.7.0
to v3.7.1 — a patch-only release with two bugfixes, no API changes, no LLVM uprev. All
investigation findings from Steps 1-2 remain valid.

Version pins already bumped from v3.6.0 → v3.7.0 (commit 0e2454c); need to update to
v3.7.1. PassPlugin.h include fix already applied (commit 546a4a9).

## Last Verified

Steps 1-2 verified 2026-06-01. Step 3 (v3.7.0 rebuild) verified 2026-06-01.

## Next Exact Step

Step 3 (repeat): Rebuild local Triton at v3.7.1 using
`triton_install.sh --triton-version v3.7.1 --local-sources ~/repos/sandbox/triton`.
Then Step 4: Build omniprobe with `cmake --build build`.
Then Step 5: Run test suite.
Then Steps 6-7: Bump version pins from v3.7.0 to v3.7.1, clean up stale v3.6.0 refs.

## Active Risks / Blockers

- Local Triton rebuild (~1-2 hours) needed for v3.7.1.
- Test execution requires bare-metal node.

## Investigation Findings

### Step 1: Patch Compatibility (PASS)
- `assert len(names) == 1` still exists at `third_party/amd/backend/compiler.py` line 465.
- `patch_triton_source()` will find and patch it correctly. No changes needed.
- v3.7.1 is a patch release; no changes to this assertion.

### Step 2: LLVM API Compatibility (ONE BREAKING CHANGE)
- LLVM hash: f6ded0be → ac5dc54d (13,287 commits apart).
- `llvm/Passes/PassPlugin.h` was **moved** to `llvm/Plugins/PassPlugin.h`.
- All 3 instrumentation pass files include the old path.
- **Fix**: Use `#if __has_include("llvm/Plugins/PassPlugin.h")` to support both LLVM versions.
- All other APIs used (Cloning, Linker, PassBuilder, Module, IR) are unchanged.
- **Already fixed** in commit 546a4a9.
- v3.7.1 uses the same LLVM hash as v3.7.0; no additional changes.

## Required Reads Before Resuming

- This handoff
- `dossier.md` in this packet (for full plan and acceptance criteria)
- `containers/triton_install.sh` lines 146-173 (patch function)
- `src/instrumentation/` (LLVM pass source files)

## Proposed Spec Changes

None.

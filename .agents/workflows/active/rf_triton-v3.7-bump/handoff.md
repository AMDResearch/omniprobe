# Handoff

## Current Status

Packet created and promoted to active. No execution steps performed yet. Investigation and
version bump work deferred to next session.

## Last Verified

N/A — workflow not yet started.

## Next Exact Step

Step 1: Verify patch compatibility. Clone or fetch Triton v3.7.0 source and check whether
`assert len(names) == 1` still exists in the AMD backend compiler.py at the expected paths.
Determine if `triton_install.sh`'s `patch_triton_source()` function needs updating.

## Active Risks / Blockers

- LLVM API compatibility unknown until Step 2 is executed.
- Local Triton rebuild (~1-2 hours) required before build/test verification.
- Test execution requires a node with mmap-capable filesystem (bare-metal, not virtiofs VM).

## Required Reads Before Resuming

- This handoff
- `dossier.md` in this packet (for full plan and acceptance criteria)
- `containers/triton_install.sh` lines 146-173 (patch function)
- `src/instrumentation/` (LLVM pass source files)

## Proposed Spec Changes

None.

# Refactor: Consistent clang-format Across All Projects

## Status
- [ ] TODO
- [ ] In Progress
- [x] Blocked
- [ ] Done

### Blocker (if blocked)
Waiting to coordinate with colleagues before the initial format commit. Need to notify team to merge/push outstanding work first.

## Objective
Establish consistent code formatting across omniprobe and its 3 submodules (dh_comms, kerneldb, instrument-amdgpu-kernels) using clang-format, with automatic enforcement via git pre-commit hooks.

## Refactor Contract

### Goal
1. Standardize `.clang-format` config across all 4 repos
2. Auto-install git pre-commit hook via CMake to format code before commits
3. Add `ninja format` / `ninja format-check` convenience targets
4. Reformat entire codebase in a single coordinated commit
5. Use `.git-blame-ignore-revs` to preserve blame history

### Non-Goals / Invariants
- ABI compatibility: n/a (formatting only)
- API compatibility: n/a (formatting only)
- Performance constraints: none
- Threading model: unchanged
- Other invariants:
  - No functional code changes — only whitespace/formatting
  - Submodules must work standalone (each needs own `.clang-format`)

### Verification Gates
- Build: `ninja` succeeds after formatting
- Tests: `ctest` passes (no functional changes)
- Format check: `ninja format-check` passes
- Hook test: Committing unformatted code results in auto-formatting

## Scope

### Affected Symbols
None — formatting only, no code changes.

### Expected Files
- `.clang-format` — create (omniprobe)
- `external/dh_comms/.clang-format` — replace (simplify)
- `external/kerneldb/.clang-format` — create
- `external/instrument-amdgpu-kernels/.clang-format` — replace
- `CMakeLists.txt` — add hook install + format targets
- `scripts/git-hooks/pre-commit` — create
- `.vscode/settings.json` — add format settings
- `README.md` — add formatting section
- `.git-blame-ignore-revs` — create (after format commit)

### Call Graph Impact
None.

### Risks
- Risk 1: Merge conflicts for colleagues with unmerged branches — mitigated by coordinating timing and having them format their branches first
- Risk 2: clang-format not available on some systems — mitigated by graceful skip in hook with warning

## Plan of Record

### Micro-steps
1. [ ] Create unified `.clang-format` config (4 lines: LLVM + customizations) — Gate: file exists
2. [ ] Copy `.clang-format` to omniprobe, dh_comms, kerneldb, instrument-amdgpu-kernels — Gate: all 4 identical
3. [ ] Create `scripts/git-hooks/pre-commit` with auto-fix behavior — Gate: script runs
4. [ ] Add CMake hook auto-install logic to `CMakeLists.txt` — Gate: cmake installs hook
5. [ ] Add CMake `format` and `format-check` targets — Gate: `ninja format-check` runs
6. [ ] Update `.vscode/settings.json` with format-on-save — Gate: file updated
7. [ ] Add formatting section to `README.md` — Gate: section exists
8. [ ] **COORDINATE**: Notify colleagues to merge outstanding work — Gate: team confirms ready
9. [ ] Run `ninja format` to reformat entire codebase — Gate: all files formatted
10. [ ] Commit formatting changes to all 4 repos — Gate: commits created
11. [ ] Create `.git-blame-ignore-revs` with format commit hash — Gate: file exists
12. [ ] Push all repos — Gate: pushed successfully

### Current Step
Blocked — waiting for team coordination (step 8)

## Progress Log

### Session 2026-03-04
- Completed: Planning and design
- Gates: n/a (planning only)
- Discovered:
  - dh_comms has detailed config, instrument-amdgpu-kernels has minimal — both LLVM-based
  - Simplified config: `BasedOnStyle: LLVM`, `ColumnLimit: 120`, `PackConstructorInitializers: Never`, `IncludeBlocks: Regroup`
  - clang-format available at `/opt/rocm/llvm/bin/clang-format`
  - Submodules need own configs (used standalone)
  - CMake can auto-install hooks on configure
  - `.git-blame-ignore-revs` preserves blame history after format commit
- Next: Coordinate with colleagues, then execute steps 1-12

## Rejected Approaches
- **Gradual formatting (format on touch)**: Rejected because commits would mix logic changes with formatting noise, making diffs hard to review.
- **Single `.clang-format` in parent only**: Rejected because submodules are used standalone and clang-format doesn't traverse past `.git` boundaries.
- **pre-commit framework (Python)**: Rejected in favor of simple shell script — fewer dependencies.

## Open Questions
None currently.

## Last Verified
Commit: N/A
Date: 2026-03-04

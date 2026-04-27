# Workflow Dossier: rf_clang-format-consistency

## Metadata
- **Type**: refactor
- **State**: active (blocked)
- **Owner**: unassigned
- **Created**: 2026-03-04 (migrated from KT)
- **Write Scope**: `.clang-format`, `CMakeLists.txt`, `scripts/git-hooks/`, `.vscode/settings.json`, `README.md`, `.git-blame-ignore-revs`, `external/dh_comms/.clang-format`, `external/kerneldb/.clang-format`
- **Dependencies**: None
- **Failure Policy**: stop

## Objective
Establish consistent code formatting across omniprobe and submodules using clang-format, with automatic enforcement via git pre-commit hooks.

## Non-Goals / Invariants
- No functional code changes — only whitespace/formatting
- Submodules must work standalone (each needs own .clang-format)

## Acceptance Criteria
1. Build: ninja succeeds after formatting
2. Tests: ctest passes
3. Format check: ninja format-check passes
4. Hook test: Committing unformatted code results in auto-formatting

## Plan of Record
1. Create unified .clang-format config (BasedOnStyle: LLVM, ColumnLimit: 120, PackConstructorInitializers: Never, IncludeBlocks: Regroup)
2. Copy .clang-format to all 4 repos (omniprobe, dh_comms, kerneldb)
3. Create scripts/git-hooks/pre-commit with auto-fix behavior
4. Add CMake hook auto-install logic to CMakeLists.txt
5. Add CMake format and format-check targets
6. Update .vscode/settings.json with format-on-save
7. Add formatting section to README.md
8. COORDINATE: Notify colleagues to merge outstanding work
9. Run ninja format to reformat entire codebase
10. Commit formatting changes to all repos
11. Create .git-blame-ignore-revs with format commit hash
12. Push all repos

## Rejected Approaches
- Gradual formatting (format on touch) — mixes logic with formatting noise
- Single .clang-format in parent only — submodules used standalone
- pre-commit framework (Python) — fewer dependencies with shell script

# Workflow Dossier: rf_test-organization

## Metadata
- **Type**: refactor
- **State**: active
- **Owner**: unassigned
- **Created**: 2026-03-06 (migrated from KT)
- **Write Scope**: `tests/`
- **Dependencies**: None
- **Failure Policy**: stop

## Objective
Establish a consistent structure for all test suites under tests/, and define guidelines for creating new tests so future additions stay consistent.

## Non-Goals / Invariants
- Don't change what the tests actually test
- Don't break run_all_tests.sh orchestration
- Keep graceful skip behavior for suites requiring env vars

## Acceptance Criteria
1. Build: cmake --build . succeeds
2. Tests: ./tests/run_all_tests.sh passes (or skips gracefully as before)

## Plan of Record
Not yet planned. Requires design decisions before execution:
1. Output location: centralized vs per-suite?
2. Handler test scripts: migrate to standalone or keep dispatcher model?
3. Shared test utilities: use test_common.sh for all suites?
4. Pre-built binaries: remove undocumented .cpp files or add build instructions?
5. Skill or template: what should new test suite template include?
6. .gitignore placement: root vs per-suite?

## Open Questions
See design decisions above.

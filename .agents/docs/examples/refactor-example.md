# Refactor Example -- Extract Auth Service

This example shows a complete workflow packet for extracting authentication
logic from Express route handlers into a standalone `AuthService` module.

---

## Starting Brief

Our Express API has authentication logic scattered across a dozen route
handlers in `src/routes/`. Each handler independently calls `bcrypt.compare`,
issues JWTs via `jsonwebtoken`, and queries the `users` table through raw
Knex calls. The duplication is making it hard to reason about token lifetimes,
and a recent audit flagged three handlers that skip the refresh-token rotation
check entirely.

I want the agent to pull all auth concerns -- password verification, token
issuance, token refresh, and session invalidation -- into a single
`src/services/auth-service.ts` module. Route handlers should delegate to that
service and never import `bcrypt` or `jsonwebtoken` directly. The public API
contract of every REST endpoint must remain identical; no request/response
shapes change.

The project uses Jest for testing and has roughly 85% coverage on the routes
layer. CI runs `npm test` and enforces the coverage threshold in
`.github/workflows/ci.yml`.

---

## Dossier

### Metadata

- Workflow ID: rf_extract_auth_service
- Workflow Type: refactor
- Lifecycle State: active
- Owner / Current Executor: agent
- Intended Write Scope: `src/services/`, `src/routes/`, `src/middleware/`, `tests/`
- Dependencies On Other Active Workflows: none

### Objective

Consolidate all authentication logic into `src/services/auth-service.ts` so
that route handlers delegate to a single service boundary. Eliminate direct
imports of `bcrypt` and `jsonwebtoken` from route files.

### Background / Context

Auth logic is duplicated across `src/routes/login.ts`, `src/routes/signup.ts`,
`src/routes/refresh.ts`, `src/routes/logout.ts`, and several protected-resource
handlers that inline token verification. A security audit identified three
handlers (`GET /api/profile`, `PUT /api/settings`, `DELETE /api/account`) that
skip refresh-token rotation. Centralizing the logic will fix these gaps and
make future changes (e.g., switching to Argon2) a single-file change.

### Contract

Behavioral equivalence: every existing integration test must pass without
modification to its request/response assertions. Only import paths and
internal wiring may change.

### Acceptance Criteria

1. `src/services/auth-service.ts` exists and exports `verifyPassword`,
   `issueTokenPair`, `refreshTokens`, and `invalidateSession`.
2. No file under `src/routes/` imports `bcrypt` or `jsonwebtoken`.
3. The three handlers flagged by the audit now call `refreshTokens` correctly.
4. `npm test` passes with no coverage regression below 85%.
5. No changes to any REST endpoint request/response contract.

### Failure Policy

`stop` -- halt and write a handoff if any integration test fails after
refactoring a route, rather than attempting speculative fixes.

### Scope

- Create `src/services/auth-service.ts` with the four exported functions.
- Update all route handlers to delegate to `AuthService`.
- Add unit tests for `AuthService` in `tests/services/auth-service.test.ts`.
- Update `src/middleware/require-auth.ts` to use `AuthService.verifyToken`.

### Non-Goals

- Changing the hashing algorithm (stays `bcrypt` for now).
- Altering token expiration times or payload structure.
- Modifying database schema or migrations.

### Constraints and Assumptions

- Node 20, TypeScript 5.4, Express 4.x.
- The `users` table schema will not change during this workflow.
- No new npm dependencies may be added.

### Dependencies

- Access to the existing test suite and CI pipeline for verification.
- The `dev` database seed (`npm run seed`) must be runnable locally.

### Plan of Record

1. Scaffold `src/services/auth-service.ts` with type signatures.
2. Migrate `verifyPassword` from `src/routes/login.ts`; update caller; run tests.
3. Migrate `issueTokenPair` from `src/routes/login.ts` and `src/routes/signup.ts`.
4. Migrate `refreshTokens` from `src/routes/refresh.ts`; fix the three audit gaps.
5. Migrate `invalidateSession` from `src/routes/logout.ts`.
6. Update `src/middleware/require-auth.ts` to use `AuthService.verifyToken`.
7. Remove stale `bcrypt`/`jsonwebtoken` imports; run full test suite.
8. Write `AuthService` unit tests and confirm coverage threshold.

### Verification Strategy

- After each migration step: run `npm test -- --testPathPattern=routes`.
- After step 6: run the full suite with `npm test`.
- Final: run `npx tsc --noEmit` and confirm zero type errors.

### References

- Security audit report: `docs/audits/2026-03-auth-review.pdf`
- Current auth flow diagram: `docs/architecture/auth-flow.mermaid`

### Open Questions

- Should `AuthService` accept a logger instance via constructor injection, or
  use the global logger? (Deferred -- keep global logger for now, revisit in
  a follow-up ticket.)

---

## Handoff Snapshot

### Current Status

Steps 1-4 of the plan complete. `verifyPassword`, `issueTokenPair`, and
`refreshTokens` are implemented in `auth-service.ts`. The three audit-flagged
handlers now call `refreshTokens`. Route-level tests pass. Steps 5-8 remain.

### Last Verified

`npm test -- --testPathPattern=routes` -- 47/47 passing (2026-04-11 14:32 UTC).

### Next Exact Step

Step 5: migrate `invalidateSession` from `src/routes/logout.ts` into
`AuthService`, update the route handler, and run route tests.

### Active Risks / Blockers

None. All routes migrated so far pass their tests.

### Required Reads Before Resuming

- `src/services/auth-service.ts` (current implementation)
- `src/routes/logout.ts` (next file to refactor)
- `tests/routes/logout.test.ts` (tests that must keep passing)

### Proposed Spec Changes

None.

---

## Run-Log Entries

### Entry 1

- Timestamp: 2026-04-11 13:05 UTC
- Actor: agent
- Planned Step: Scaffold `auth-service.ts` and migrate `verifyPassword`
- Action Taken: Created `src/services/auth-service.ts` with `verifyPassword`.
  Updated `src/routes/login.ts` to import from `AuthService`.
- Result: success
- Files Touched: `src/services/auth-service.ts` (created), `src/routes/login.ts`
- Verification Run: `npm test -- --testPathPattern=login` -- 12/12 passing
- Criteria Impact: criteria 1 partially met, criteria 2 partially met
- Blocker or Risk: none

### Entry 2

- Timestamp: 2026-04-11 13:48 UTC
- Actor: agent
- Planned Step: Migrate `issueTokenPair` from login and signup routes
- Action Taken: Added `issueTokenPair` to `AuthService`. Updated
  `src/routes/login.ts` and `src/routes/signup.ts`.
- Result: success
- Files Touched: `src/services/auth-service.ts`, `src/routes/login.ts`,
  `src/routes/signup.ts`
- Verification Run: `npm test -- --testPathPattern=routes` -- 47/47 passing
- Criteria Impact: criteria 1 and 2 progressing
- Blocker or Risk: none

### Entry 3

- Timestamp: 2026-04-11 14:30 UTC
- Actor: agent
- Planned Step: Migrate `refreshTokens` and fix audit gaps
- Action Taken: Added `refreshTokens` to `AuthService`. Updated
  `src/routes/refresh.ts`. Fixed `GET /api/profile`, `PUT /api/settings`,
  `DELETE /api/account` to call `refreshTokens` before responding.
- Result: success
- Files Touched: `src/services/auth-service.ts`, `src/routes/refresh.ts`,
  `src/routes/profile.ts`, `src/routes/settings.ts`, `src/routes/account.ts`
- Verification Run: `npm test -- --testPathPattern=routes` -- 47/47 passing
- Criteria Impact: criteria 3 met, criteria 1 and 2 progressing
- Blocker or Risk: none

---

## Artifacts

| Artifact | Path | Description |
|----------|------|-------------|
| Auth service module | `src/services/auth-service.ts` | New consolidated auth service |
| Route-test results | `artifacts/rf_extract_auth_service/route-tests-step4.txt` | Jest output after step 4 (47/47 pass) |
| Type-check log | `artifacts/rf_extract_auth_service/tsc-noEmit-step4.txt` | `npx tsc --noEmit` output, zero errors |

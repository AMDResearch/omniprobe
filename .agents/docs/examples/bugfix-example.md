# Bug Fix Example -- Premature Session Expiration

This example shows a complete workflow packet for diagnosing and fixing a bug
where user sessions expire after 60 seconds instead of the intended 30 minutes.

---

## Starting Brief

Users are reporting that they get logged out roughly one minute after signing
in. The expected session lifetime is 30 minutes. The problem appeared after
last Wednesday's deploy (commit `a4c82f1`, "Migrate session store to Redis").
Before that deploy, sessions used the default in-memory store and the timeout
worked correctly.

The session middleware is configured in `src/middleware/session.ts` and uses
`express-session` with `connect-redis`. The `SESSION_TTL` environment variable
is set to `1800` in `.env.production`. The Redis instance is a managed
ElastiCache cluster (Redis 7.x). I suspect the TTL is being interpreted in the
wrong unit somewhere, but I have not dug into the code yet.

I need the agent to find the root cause, fix it, and add a regression test
that would catch this class of bug in the future. The fix should be minimal --
no architectural changes to the session layer.

---

## Dossier

### Metadata

- Workflow ID: bf_session_expiry
- Workflow Type: bug fix
- Lifecycle State: active
- Owner / Current Executor: agent
- Intended Write Scope: `src/middleware/session.ts`, `tests/middleware/`
- Dependencies On Other Active Workflows: none

### Objective

Fix premature session expiration so that sessions last 30 minutes as intended,
and add a regression test covering TTL propagation to the Redis store.

### Background / Context

The session middleware was migrated from the default in-memory store to
`connect-redis` in commit `a4c82f1` (2026-04-09). The `express-session`
`cookie.maxAge` option expects milliseconds, but the `connect-redis` `ttl`
option expects seconds. The migration set both values to `process.env.SESSION_TTL`
(1800) without converting units, causing `cookie.maxAge` to be 1800 ms
(1.8 seconds, rounded to ~60 seconds by the browser) while the Redis key TTL
is correctly set to 1800 seconds.

### Contract

After the fix, sessions must survive for the full `SESSION_TTL` duration
(1800 seconds = 30 minutes). The fix must not alter the Redis key TTL behavior,
which is already correct.

### Acceptance Criteria

1. `cookie.maxAge` is set to `SESSION_TTL * 1000` (converting seconds to ms).
2. Redis store `ttl` remains set to `SESSION_TTL` (already in seconds).
3. A new integration test in `tests/middleware/session.test.ts` asserts that the
   cookie `Max-Age` header value equals `SESSION_TTL` (in seconds, as
   `Set-Cookie` uses seconds).
4. `npm test` passes with no regressions.
5. Manual verification: after deploying to staging, a session persists for at
   least 5 minutes without being destroyed.

### Failure Policy

`stop` -- halt if the root cause differs from the unit mismatch hypothesis and
document findings in the handoff for human review.

### Scope

- Fix the `cookie.maxAge` value in `src/middleware/session.ts`.
- Add or update integration test in `tests/middleware/session.test.ts`.

### Non-Goals

- Refactoring the session middleware architecture.
- Changing the session TTL value itself.
- Migrating away from `connect-redis`.
- Fixing any other session-related issues not related to expiration timing.

### Constraints and Assumptions

- Node 20, Express 4.x, `express-session` 1.18, `connect-redis` 7.x.
- `SESSION_TTL` env var is always specified in seconds.
- The Redis store TTL is already correct; only the cookie maxAge is wrong.

### Dependencies

- Access to a local Redis instance for integration tests (`docker compose up redis`).
- The `.env.test` file must set `SESSION_TTL=1800`.

### Plan of Record

1. Read `src/middleware/session.ts` and confirm the root cause (unit mismatch).
2. Read the `connect-redis` and `express-session` documentation to confirm
   expected units for `ttl` and `cookie.maxAge`.
3. Fix `cookie.maxAge` to use `SESSION_TTL * 1000`.
4. Write an integration test asserting correct `Set-Cookie` Max-Age header.
5. Run `npm test` and confirm all tests pass.

### Verification Strategy

- After step 3: inspect the diff to confirm only the `maxAge` line changed.
- After step 5: `npm test` must pass, including the new test.
- Post-deploy: monitor staging session durations for one hour to confirm
  no premature logouts.

### References

- Regression commit: `a4c82f1` ("Migrate session store to Redis")
- `express-session` docs: `cookie.maxAge` is in milliseconds
- `connect-redis` docs: `ttl` is in seconds
- User reports: Slack thread #support 2026-04-10

### Open Questions

- None. Root cause is confirmed.

---

## Handoff Snapshot

### Current Status

Root cause confirmed (step 1-2 done). The fix has been applied and the
regression test written (steps 3-4 done). Awaiting full test suite run
(step 5).

### Last Verified

`npm test -- --testPathPattern=session` -- 8/8 passing including 1 new test
(2026-04-11 10:22 UTC).

### Next Exact Step

Step 5: run the full test suite with `npm test` to confirm no regressions
across the entire codebase.

### Active Risks / Blockers

None. The fix is a one-line change; risk of side effects is minimal.

### Required Reads Before Resuming

- `src/middleware/session.ts` (the fixed file)
- `tests/middleware/session.test.ts` (the new regression test)

### Proposed Spec Changes

None.

---

## Run-Log Entries

### Entry 1

- Timestamp: 2026-04-11 10:02 UTC
- Actor: agent
- Planned Step: Read session middleware and confirm root cause
- Action Taken: Read `src/middleware/session.ts`. Found line 14:
  `cookie: { maxAge: parseInt(process.env.SESSION_TTL) }`. The value 1800 is
  passed as milliseconds (1.8 seconds). The `connect-redis` `ttl` on line 22
  correctly uses `parseInt(process.env.SESSION_TTL)` (seconds). Root cause
  confirmed: unit mismatch on `cookie.maxAge`.
- Result: root cause confirmed
- Files Touched: none (read-only investigation)
- Verification Run: n/a
- Criteria Impact: informs criteria 1
- Blocker or Risk: none

### Entry 2

- Timestamp: 2026-04-11 10:12 UTC
- Actor: agent
- Planned Step: Fix `cookie.maxAge` and write regression test
- Action Taken: Changed line 14 in `src/middleware/session.ts` to
  `cookie: { maxAge: parseInt(process.env.SESSION_TTL) * 1000 }`. Added a
  test in `tests/middleware/session.test.ts` that creates a session via
  Supertest, parses the `Set-Cookie` header, and asserts `Max-Age=1800`.
- Result: success
- Files Touched: `src/middleware/session.ts`, `tests/middleware/session.test.ts`
- Verification Run: `npm test -- --testPathPattern=session` -- 8/8 passing
- Criteria Impact: criteria 1, 2, 3 met
- Blocker or Risk: none

### Entry 3

- Timestamp: 2026-04-11 10:22 UTC
- Actor: agent
- Planned Step: Run full test suite
- Action Taken: Ran `npm test`. All 247 tests pass. No coverage regression.
- Result: success
- Files Touched: none (verification only)
- Verification Run: `npm test` -- 247/247 passing, coverage 86.2%
- Criteria Impact: criteria 4 met
- Blocker or Risk: none -- criteria 5 (staging verification) requires deploy

---

## Artifacts

| Artifact | Path | Description |
|----------|------|-------------|
| Fix diff | `artifacts/bf_session_expiry/fix.patch` | One-line diff for `session.ts` maxAge |
| Regression test | `tests/middleware/session.test.ts` | New test asserting `Max-Age=1800` in Set-Cookie |
| Full test output | `artifacts/bf_session_expiry/test-results.txt` | `npm test` output, 247/247 pass |
| Root cause analysis | `artifacts/bf_session_expiry/root-cause.md` | Summary of unit mismatch with code references |

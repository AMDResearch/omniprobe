# Tutorial: Bug-Fix Session -- Session Timeout Expires After 60 Seconds

This walkthrough follows the two-session lifecycle for a bug-fix workflow.
A developer reports sessions expiring far too quickly. The agent turns the
report into a diagnosis-and-fix plan, then resolves it in a follow-up session.

---

## Session 1: Refine the Request

The user describes the bug and invokes `workflow-refine`.

> We have a bug causing customer complaints. User sessions are expiring
> after exactly 60 seconds instead of the configured 30-minute timeout.
> Users get kicked to the login page mid-form, causing data loss.
>
> I first noticed it Monday after a support escalation. I checked
> `config/session.ts` and the timeout is correctly set to `1800` seconds.
> The session module at `src/middleware/session.ts` has no recent changes
> per git log. The configuration looks right on paper.
>
> The important detail: this only affects users on the v3 API (`/api/v3/*`
> routes). The legacy v2 API works fine. Both share the same session config
> file. We did update several dependencies about two weeks ago.
>
> Use `workflow-refine` to turn this into a bug-fix workflow.

The agent checks the dossier template, `active-workflows.md`, and
`pm-index.md` for session architecture notes, then asks four questions.

> 1. **Reproduction.** Can you reliably reproduce the 60-second expiry? For
>    example, log in via v3, wait 90 seconds, hit a protected endpoint --
>    consistent 401?
> 2. **Server logs.** Does anything appear when a session expires? Any detail
>    about why it was rejected (expired, not found, bad signature)?
> 3. **Session store.** Is v3 using Redis, in-memory, or something else? Same
>    store instance as v2?
> 4. **Dependency update.** Which packages were updated two weeks ago?
>    Specifically, was the session middleware library (e.g., `express-session`,
>    `connect-redis`) part of that update?

> 1. Completely reproducible. Wait 65 seconds, hit any protected endpoint --
>    401 every time. At 55 seconds it works. Cutoff is exactly 60 seconds.
> 2. Logs show `Session expired: sid=<id>` from the session middleware. No
>    additional detail.
> 3. Both v2 and v3 use Redis, same instance. Connection config is shared in
>    `config/redis.ts`. But -- v3 initializes its own session middleware in
>    `src/api/v3/setup.ts` while v2 uses `src/middleware/session.ts` directly.
> 4. Two weeks ago we updated `connect-redis` from 7.1.0 to 8.0.0 and
>    `express-session` from 1.17.3 to 1.18.0 in the same PR. That matches
>    exactly when complaints started.

The agent presents the refined dossier.

> This points strongly at a `connect-redis` v8 breaking change in TTL config.
>
> **Workflow ID:** `bf_v3-session-timeout-60s` | **Type:** Bug Fix
>
> **Objective:** Fix the v3 API session timeout so sessions expire after the
> configured 1800 seconds instead of 60 seconds. v2 must remain unaffected.
>
> **Background:** Sessions on `/api/v3/*` expire after exactly 60 seconds.
> Started ~2 weeks ago with a dependency update bumping `connect-redis` 7.1.0
> to 8.0.0 and `express-session` 1.17.3 to 1.18.0. The v3 API initializes
> its own session middleware in `src/api/v3/setup.ts` (separate from v2's
> `src/middleware/session.ts`). Both use the same Redis instance and config.
>
> **Acceptance Criteria:** A v3 session survives at least 1800 seconds
> (verified by TTL inspection test). v2 behavior unchanged. Existing tests
> pass. A regression test guards against TTL reverting to 60s. Root cause
> documented in run-log.
>
> **Scope:** `src/api/v3/setup.ts` (primary suspect), `config/session.ts`
> (if config shape needs updating), and test files.
>
> **Non-Goals:** Refactoring v2 session setup or unifying v2/v3. Upgrading
> Redis. Changing the 1800-second value. Adding session monitoring.
>
> **Failure Policy:** `stop` if root cause cannot be confirmed -- report
> findings rather than applying a speculative fix.
>
> **Plan of Record:** (1) Reproduce: write a test that inspects Redis TTL
> for a v3 session and asserts 1800. (2) Read `connect-redis` 8.0.0
> changelog for TTL breaking changes. (3) Compare how v3 setup passes TTL
> vs what v8 expects; compare with v2 to see why it still works. (4) Apply
> fix. (5) Verify reproduction test passes. (6) Run full suite. (7) Add
> permanent regression test.

The user approves and the agent creates the packet at
`.agents/workflows/active/bf_v3-session-timeout-60s/`.

---

## Handoff State After Session 1

```
Current Status: Packet created. Dossier approved. No code changes.
Next Exact Step: Write a reproduction test inspecting Redis TTL for a
  v3 session (expect it to be 60, confirming the bug). Then read the
  connect-redis 8.0.0 changelog.
Active Risks: Strong hypothesis but not yet confirmed.
Required Reads: dossier.md; src/api/v3/setup.ts; src/middleware/session.ts;
  config/session.ts; package.json.
```

---

## Session 2: Resume and Execute

> Use `workflow-resume` and continue `bf_v3-session-timeout-60s` from handoff.

The agent reads `handoff.md`, then `dossier.md`, checks
`active-workflows.md`, reads the three source files from the required-reads
list, and appends a session-start entry to `run-log.md`.

The agent works through the plan:

1. **Reproduce.** Writes `tests/api/v3/session-timeout.test.ts`. Creates a
   v3 session and inspects the Redis TTL -- it is 60, not 1800. Bug
   confirmed. Recorded in `run-log.md`.

2. **Diagnose.** Reads the `connect-redis` 8.0.0 changelog. Breaking change:
   in v7, TTL was passed as a flat `ttl` option on the store constructor. In
   v8, that option is silently ignored and the default TTL is 60 seconds.
   The library now expects TTL via the new config object format.

   Compares the setup files: `src/middleware/session.ts` (v2) still works
   because it imports via a compatibility shim that maps the old API. But
   `src/api/v3/setup.ts` uses the v8 import directly and passes `ttl: 1800`
   in the v7 style -- silently ignored by v8, falling back to 60 seconds.

   Root cause confirmed and recorded in `run-log.md`.

3. **Fix.** Updates `src/api/v3/setup.ts` to pass TTL using the v8
   configuration format. Three-line change.

4. **Verify.** Reproduction test now shows TTL of 1800. Test passes.

5. **Regression check.** `npm test` -- all 140 existing tests pass. v2
   session tests still green.

6. **Regression test.** Marks the reproduction test as permanent. Adds a
   comment explaining the `connect-redis` v8 breaking change it guards
   against. The test asserts TTL equals the value from `config/session.ts`.

7. **Final run.** `npm test` -- 141 tests pass (1 new). Updates
   `artifacts.md` with test output and a link to the changelog entry.

Final handoff:

```
Current Status: Complete. Root cause: connect-redis v8 silently ignores
  the v7 TTL option, defaulting to 60s. Fix applied to src/api/v3/setup.ts
  (3-line change). Regression test added. Suite passes (141/141).
Next Exact Step: None -- ready for human review and closure.
Note: Consider updating v2 setup to use v8 API for consistency (out of
  scope for this fix).
```

---

## What the User Reviews

- **`dossier.md`** -- confirm acceptance criteria were not modified.
- **`handoff.md`** -- final status, root cause summary, and test results.
- **`run-log.md`** -- the diagnosis trail is worth reading for this type of
  workflow to verify the root-cause reasoning.
- **`artifacts.md`** -- test evidence and changelog reference.
- **The diff** -- the 3-line fix in `src/api/v3/setup.ts` and the new
  regression test.

The agent flagged a follow-up: the v2 setup file still uses the old API via
a compatibility shim. The user may create a separate refactor workflow for
that, but it is outside this bug fix's scope.

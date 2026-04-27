# Tutorial: Refactor Session -- Extracting an Auth Service

This walkthrough follows the two-session lifecycle for a refactor workflow.
A developer extracts authentication logic from scattered route handlers into
a standalone service module.

---

## Session 1: Refine the Request

The user describes the problem and invokes `workflow-refine`.

> I need to refactor authentication in our Express app. The auth logic --
> password hashing, token generation, OAuth callback handling, and role
> checks -- is copy-pasted across four route files: `src/routes/login.ts`,
> `signup.ts`, `oauth-callback.ts`, and `admin.ts`. Each has its own
> slightly different token-verification middleware.
>
> Testing is painful because every route test mocks the full auth chain
> individually. When we changed JWT expiry last month we patched it in four
> places and still missed one. The security team has flagged the lack of a
> single source of truth.
>
> I want a standalone `src/services/auth-service.ts` that owns all auth
> logic. The route handlers should call into it. The Passport/OAuth wiring
> can stay in the routes -- I only want internal logic extracted. Nothing
> about the external API should change, and the existing suite (~140 tests,
> `npm test`) must keep passing.
>
> Use `workflow-refine` to turn this into a refactor workflow.

The agent checks the dossier template, `active-workflows.md`, and `pm-index.md`,
then asks clarifying questions in one batch.

> 1. **Test coverage.** Do you want new unit tests for `auth-service.ts`, or
>    is the existing suite sufficient?
> 2. **OAuth boundary.** Should `deserializeUser`/`serializeUser` move into
>    the auth service, or stay in the route files?
> 3. **Internal signatures.** Can the internal call signatures change freely,
>    or does external code depend on them?
> 4. **Failure policy.** If auth logic in one file is deeply entangled with
>    business logic, should I stop or make a best-effort partial extraction?

> 1. Yes, add unit tests for token generation, token verification, and role
>    checking. Major paths, not every edge case.
> 2. Keep `serializeUser` and `deserializeUser` in the routes.
> 3. Internal signatures can change freely. Nothing outside this repo uses them.
> 4. Stop and report. I want to know about entanglement before you proceed.

The agent presents the refined dossier.

> **Workflow ID:** `rf_extract-auth-service` | **Type:** Refactor
>
> **Objective:** Extract all auth logic from the four route files into
> `src/services/auth-service.ts` so auth policy has a single source of truth.
>
> **Acceptance Criteria:** `auth-service.ts` exports functions for token
> generation, verification, hashing, and role checking. The four route files
> delegate to it. No duplicate auth logic remains. Existing tests pass
> unmodified. New unit tests cover the service. API endpoints unchanged.
>
> **Scope:** `src/services/auth-service.ts` (new), the four route files,
> `tests/services/auth-service.test.ts` (new), related type imports.
>
> **Non-Goals:** Moving Passport config. Changing API contracts. Refactoring
> nearby business logic. Performance optimization.
>
> **Failure Policy:** `stop` if clean separation is not possible.
>
> **Plan of Record:** (1) Audit route files, catalog auth functions.
> (2) Create `auth-service.ts`. (3-6) Rewire each route file one at a time,
> running `npm test` after each. (7) Write service unit tests.
> (8) Final test run and verification summary.

The user approves and the agent creates the packet at
`.agents/workflows/active/rf_extract-auth-service/`.

---

## Handoff State After Session 1

```
Current Status: Packet created. Dossier approved. No code changes.
Next Exact Step: Audit the four route files and catalog every auth-related
  function and middleware. Record the catalog in run-log.md.
Active Risks: Possible entanglement in admin.ts (watch item).
Required Reads: dossier.md; the four route source files.
```

---

## Session 2: Resume and Execute

> Use `workflow-resume` and continue `rf_extract-auth-service` from handoff.

The agent reads `handoff.md`, then `dossier.md` (Objective, Acceptance
Criteria, Scope, Non-Goals), confirms no write-scope conflicts in
`active-workflows.md`, and appends a session-start entry to `run-log.md`.

The agent works through the plan:

1. **Audit.** Reads the four route files, catalogs 11 auth functions and 3
   middleware definitions in `run-log.md`.
2. **Create service.** Writes `auth-service.ts` with consolidated functions.
   Runs `npm test` -- 140 pass (new file not yet called).
3. **Rewire routes.** Updates each route file to call the service. Runs
   `npm test` after each -- all pass.
4. **New tests.** Creates `auth-service.test.ts` covering token generation,
   verification, and role checks. Suite grows to 152 tests, all pass.
5. **Final verification.** Full `npm test` run, 152/152 pass. Updates
   `artifacts.md` with test output.

Final handoff:

```
Current Status: Complete. Auth logic consolidated. Four routes rewired.
  12 new tests. Full suite passes (152/152).
Next Exact Step: None -- ready for human review and closure.
```

---

## What the User Reviews

- **`dossier.md`** -- confirm acceptance criteria were not changed.
- **`handoff.md`** -- final status and verification result.
- **`artifacts.md`** -- test evidence.
- **The diff** -- the new service file and four updated route files.

The user does not need `run-log.md` unless they want step-by-step history.

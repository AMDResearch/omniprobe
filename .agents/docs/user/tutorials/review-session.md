# Review Session Tutorial

This walkthrough shows how to use the two-session pattern for a code review workflow. The user asks for a thorough review of a recently merged payment retry mechanism. The agent refines the request into a structured review packet, and a second session executes the review and reports findings.

---

## Session 1: Refine the Review

### Step 1 --- The User Describes the Review Request

> I need a thorough review of the payment retry mechanism that was added last week. A junior engineer on my team implemented it. The PR (#312) is already merged to main, but we haven't deployed to production yet, so there's still time to address issues before it goes live.
>
> My main concerns are around edge cases. Specifically: idempotency handling --- if a retry fires while the original request is still in flight, could we end up with duplicate charges? Error handling when the payment gateway times out --- does the retry logic handle partial failures correctly, or could it leave transactions in a bad state? And generally, whether the retry backoff and max-attempt logic is sound.
>
> The scope is review-only. I want you to read the code, identify issues, and report findings. Don't change any code --- I want to discuss findings with the engineer first and have them make the fixes.

### Step 2 --- The Agent Asks Clarifying Questions

> **Agent:** Before I build the review dossier, a few questions:
>
> 1. **Which files contain the retry logic?** Is it concentrated in one module (e.g., `src/payments/retry.ts`) or spread across multiple files? If you can point me to the main entry points I'll make sure nothing gets missed.
>
> 2. **What is the payment gateway's idempotency model?** Does it support idempotency keys (like Stripe does), or does your code need to manage deduplication itself? This affects how I evaluate the duplicate-charge risk.
>
> 3. **Are there existing integration tests for the retry path?** I want to know whether to flag missing test coverage as a finding, or whether tests are expected to come later in a separate PR.
>
> 4. **Should I cover only correctness, or also performance characteristics?** For example, if the retry logic uses blocking sleeps in an async context, should I flag that, or is throughput not a concern at your current scale?

### Step 3 --- The User Responds

> 1. The main retry logic is in `src/payments/retry_handler.ts`. It calls into `src/payments/gateway_client.ts` for the actual gateway communication and uses `src/payments/idempotency.ts` for key management. There's also a retry configuration in `src/config/payment_config.ts`.
>
> 2. Our gateway (it's a Stripe-like provider) supports idempotency keys. You pass a key with the request and the gateway guarantees at-most-once processing for that key within 24 hours. Our `idempotency.ts` module generates and stores these keys.
>
> 3. There are a few unit tests in `src/payments/__tests__/retry_handler.test.ts` but no integration tests yet. Flagging test gaps is welcome --- I'd like to know what's missing.
>
> 4. Good question. Yes, please flag performance issues too. We process about 50k payments per day and it's growing, so blocking sleeps or unbounded retry loops would be a real problem.

### Step 4 --- The Agent Produces the Refined Dossier

The agent creates `.agents/workflows/draft/rv_payment_retry/` with the following `dossier.md`:

> **Metadata**
> - Workflow ID: `rv_payment_retry`
> - Workflow Type: review
> - Lifecycle State: draft
> - Owner: (user)
> - Intended Write Scope: review artifacts only; no code changes
> - Dependencies: none
>
> **Objective**
>
> Review the payment retry mechanism (PR #312) for correctness, safety, and performance issues before production deployment.
>
> **Background / Context**
>
> A junior engineer implemented payment retry logic across four files: `retry_handler.ts`, `gateway_client.ts`, `idempotency.ts`, and `payment_config.ts`. The code is merged to main but not yet deployed. The gateway supports idempotency keys with a 24-hour window. Current volume is ~50k payments/day. Some unit tests exist; no integration tests.
>
> **Acceptance Criteria**
> 1. All four files listed above are reviewed for correctness and edge cases.
> 2. Each finding includes: severity (critical / warning / info), file and line reference, description of the issue, and why it matters.
> 3. Specific attention is paid to: duplicate-charge risk, timeout handling, idempotency key lifecycle, and retry backoff behavior.
> 4. Test coverage gaps are documented.
> 5. Performance concerns at 50k+ payments/day scale are flagged.
> 6. Findings are reported in a summary; no code is modified.
>
> **Failure Policy:** `best_effort` --- if some files cannot be fully evaluated (e.g., opaque gateway SDK internals), note the limitation and review what is visible.
>
> **Scope**
> - `src/payments/retry_handler.ts` --- retry orchestration and backoff logic.
> - `src/payments/gateway_client.ts` --- gateway communication and timeout handling.
> - `src/payments/idempotency.ts` --- idempotency key generation, storage, and reuse.
> - `src/config/payment_config.ts` --- retry limits, backoff intervals, timeout values.
> - `src/payments/__tests__/retry_handler.test.ts` --- existing test coverage.
>
> **Non-Goals**
> - Modifying any code (findings-only review).
> - Reviewing unrelated payment code outside the retry path.
> - Implementing integration tests (though gaps will be flagged).
> - Reviewing the gateway provider's SDK internals.
>
> **Plan of Record**
> 1. Read `payment_config.ts` to understand the retry parameters (max attempts, backoff strategy, timeout values).
> 2. Review `idempotency.ts` for key generation, storage, expiry, and reuse-on-retry behavior.
> 3. Review `gateway_client.ts` for timeout handling, partial failure states, and how idempotency keys are passed.
> 4. Review `retry_handler.ts` for orchestration correctness: retry triggers, backoff implementation, max-attempt enforcement, and concurrent-request safety.
> 5. Review existing tests for coverage of edge cases (timeout, partial failure, duplicate key, max retries exhausted).
> 6. Compile findings into a prioritized report.

### Step 5 --- The User Reviews and Approves

> Looks good. The scope covers exactly what I want. Go ahead.

The agent moves the packet to `active/rv_payment_retry/` and writes the initial `handoff.md`:

> **Current Status:** Dossier approved. Review has not started.
>
> **Next Exact Step:** Read `src/config/payment_config.ts` to establish the retry configuration parameters, then proceed to `idempotency.ts`.
>
> **Active Risks / Blockers:** None.
>
> **Required Reads Before Resuming:** `dossier.md` in this packet.

---

## Session 2: Execute the Review

### Step 6 --- The User Starts the Execution Session

> Resume the `rv_payment_retry` review workflow from its handoff and complete the review.

### Step 7 --- The Agent Picks Up from Handoff

The agent reads `handoff.md`, then `dossier.md`, and works through the plan of record. It reviews each file in sequence, recording observations in `run-log.md` and compiling findings as it goes.

After completing the review, the agent reports:

> **Review Findings --- Payment Retry Mechanism (PR #312)**
>
> **Critical (2 findings)**
>
> 1. **Missing idempotency key on retry after timeout** (`gateway_client.ts:87-94`)
>    When the gateway returns a timeout error, `retry_handler.ts` calls `gateway_client.send()` again, but the catch block in `gateway_client.ts` discards the original request context, including the idempotency key. The retry sends a new request without a key, meaning the gateway treats it as a new charge. If the original timed-out request actually succeeded on the gateway side, this produces a duplicate charge.
>
> 2. **No concurrency guard on retry scheduling** (`retry_handler.ts:45-60`)
>    The retry handler uses `setTimeout` to schedule retries but does not track in-flight requests. If the original request completes (successfully or with a non-retryable error) while a retry is already queued, both the original response handler and the retry can proceed simultaneously. In the worst case, this leads to double processing of a successful payment.
>
> **Warning (3 findings)**
>
> 3. **Backoff uses fixed intervals, not exponential** (`retry_handler.ts:32`)
>    The retry delay is set to a constant 2000 ms from `payment_config.ts`. At 50k payments/day, a burst of failures would produce a wall of retries hitting the gateway simultaneously 2 seconds later. Exponential backoff with jitter would be safer at scale.
>
> 4. **Idempotency keys are stored in memory only** (`idempotency.ts:15-22`)
>    Keys are held in a `Map` that is lost on process restart. If the payment service restarts between the original request and a scheduled retry, the retry cannot find its idempotency key and generates a new one, which re-introduces the duplicate-charge risk from finding #1 through a different path.
>
> 5. **Gateway timeout is set to 30 seconds** (`payment_config.ts:8`)
>    This is unusually long for a payment gateway call. If the gateway is slow, the retry handler holds the connection for 30 seconds before starting the backoff timer. At scale, this could exhaust the connection pool. A 5-10 second timeout with faster retry is more typical.
>
> **Info (2 findings)**
>
> 6. **Max retry count is 5** (`payment_config.ts:3`)
>    This is reasonable but should be documented. With fixed 2-second backoff, worst case is 10 seconds of retries. With exponential backoff, the total retry window would be longer; this may need adjustment if backoff is changed.
>
> 7. **Test coverage gaps** (`retry_handler.test.ts`)
>    Existing tests cover the happy path (succeed on first try) and a simple retry-then-succeed case. Missing tests: timeout followed by retry, max retries exhausted, concurrent request interleaving, process restart during retry window, and idempotency key reuse verification.
>
> **Recommended priority:** Fix findings #1 and #2 before production deployment. Address #3 and #4 in the same pass if possible. #5 can be evaluated with the team.

### Step 8 --- The Agent Updates Handoff and Closes

The agent writes the final `handoff.md`:

> **Current Status:** Review complete. Seven findings documented (2 critical, 3 warning, 2 info).
>
> **Last Verified:** All four source files and the test file reviewed per plan of record.
>
> **Next Exact Step:** None; awaiting user review of findings. Critical items #1 and #2 should be addressed before production deployment.
>
> **Active Risks / Blockers:** None.

### Step 9 --- What the User Reviews

At the end of the review, the user typically reads:

- **The findings summary above** --- prioritized by severity with file and line references.
- **`artifacts.md`** --- if the agent captured code excerpts or annotated snippets as supporting detail.
- **`dossier.md`** --- only to confirm the acceptance criteria (all four files reviewed, findings prioritized, test gaps noted) were met.

The user does not usually need to read `run-log.md` unless they want to trace the agent's reasoning about a specific finding. The workflow can be moved to `done/rv_payment_retry/` once findings are acknowledged, or kept active if the user wants a follow-up review after fixes are made.

# Review Example -- Payment Retry Mechanism

This example shows a complete workflow packet for reviewing a payment retry
mechanism for idempotency guarantees and edge-case correctness.

---

## Starting Brief

We recently merged a payment retry mechanism in PR #482 that automatically
retries failed charges up to three times with exponential backoff. The
implementation spans the `PaymentProcessor` service, a new `RetryScheduler`,
and a webhook handler that reconciles Stripe events with local state. The
feature passed functional testing but has not received a thorough review
for idempotency, race conditions, or failure-mode correctness.

I want the agent to review the retry mechanism with a focus on three areas:
(1) idempotency -- can a charge ever be applied twice if a retry races with a
delayed success webhook? (2) edge cases -- what happens when the Stripe API
returns ambiguous errors (e.g., network timeout where the charge may or may
not have succeeded)? (3) test coverage -- are the existing tests sufficient
to catch regressions in retry logic, or are there meaningful gaps?

The implementation is in `src/payments/processor.ts`,
`src/payments/retry-scheduler.ts`, and `src/webhooks/stripe-handler.ts`.
Tests are in `tests/payments/` and `tests/webhooks/`.

---

## Dossier

### Metadata

- Workflow ID: rv_payment_retry
- Workflow Type: review
- Lifecycle State: active
- Owner / Current Executor: agent
- Intended Write Scope: `artifacts/rv_payment_retry/` only (no code changes)
- Dependencies On Other Active Workflows: none

### Objective

Produce a structured review of the payment retry mechanism covering
idempotency, edge-case handling, and test coverage gaps. Deliver findings
as a prioritized list with file references and severity ratings.

### Background / Context

The retry mechanism was implemented in PR #482 (merged 2026-04-08). The
`PaymentProcessor.chargeCustomer()` method calls the Stripe
`paymentIntents.create` API. On failure, it enqueues a retry job in
`RetryScheduler` (backed by BullMQ on Redis). The scheduler runs retries
with exponential backoff (1 min, 5 min, 25 min). The `StripeWebhookHandler`
listens for `payment_intent.succeeded` and `payment_intent.payment_failed`
events and updates the local `payments` table.

The idempotency key is currently set to `payment_${orderId}_${attemptNumber}`,
which means each retry uses a different idempotency key. This is the primary
area of concern.

### Contract

The review is complete when all three focus areas have been examined and
findings are documented with file references, severity ratings, and
recommended actions.

### Acceptance Criteria

1. Idempotency analysis: document whether double-charging is possible and
   under what conditions, with specific code references.
2. Edge-case analysis: document behavior for at least these scenarios:
   - Stripe timeout (charge status unknown)
   - Webhook arrives before retry completes
   - Webhook arrives after max retries exhausted
   - Concurrent retries (scheduler fires twice due to Redis failover)
3. Test coverage gap analysis: list untested paths with file and line refs.
4. All findings assigned severity (critical / high / medium / low).
5. Findings report delivered in `artifacts/rv_payment_retry/review-findings.md`.

### Failure Policy

`best_effort` -- deliver findings on whatever has been reviewed even if the
full scope cannot be completed.

### Scope

Files to review:
- `src/payments/processor.ts` (charge logic and idempotency key generation)
- `src/payments/retry-scheduler.ts` (BullMQ job scheduling and backoff)
- `src/webhooks/stripe-handler.ts` (webhook reconciliation)
- `src/payments/payment.entity.ts` (database model and status enum)
- `tests/payments/processor.test.ts`
- `tests/payments/retry-scheduler.test.ts`
- `tests/webhooks/stripe-handler.test.ts`

### Non-Goals

- Implementing fixes for any findings (separate workflow required).
- Reviewing Stripe SDK version or configuration.
- Reviewing non-payment webhooks.
- Load testing or performance analysis of the retry queue.

### Constraints and Assumptions

- Review is static analysis only (code reading + reasoning); no runtime tests.
- The Stripe API behavior is as documented in their official API reference.
- BullMQ job processing guarantees "at least once" delivery.

### Dependencies

- Access to the merged PR #482 diff for context on what changed.
- Stripe API documentation for `paymentIntents.create` idempotency behavior.

### Plan of Record

1. Read `processor.ts` and analyze idempotency key generation and charge flow.
2. Read `retry-scheduler.ts` and analyze job lifecycle, deduplication, and
   backoff logic.
3. Read `stripe-handler.ts` and analyze webhook reconciliation against
   the retry state machine.
4. Map the state transitions in `payment.entity.ts` and identify illegal or
   unhandled transitions.
5. Review all three test files for coverage of the identified edge cases.
6. Write the findings report.

### Verification Strategy

- Each finding must include the specific file path and line number(s).
- Each finding must include a severity rating and a concrete scenario that
  triggers the issue.
- The report must be self-contained: a reader should not need to re-derive
  any finding.

### References

- PR #482: payment retry implementation
- Stripe idempotency docs: `https://stripe.com/docs/api/idempotent_requests`
- BullMQ docs: `https://docs.bullmq.io/guide/jobs/stalled`
- Payment state machine: `docs/architecture/payment-states.mermaid`

### Open Questions

- Is there a database-level unique constraint on
  `(order_id, stripe_payment_intent_id)` that would prevent duplicate charges
  at the data layer? (Will check during step 4.)

---

## Handoff Snapshot

### Current Status

Steps 1-4 complete. Idempotency analysis found a critical issue: the
per-attempt idempotency key allows Stripe to create multiple
`PaymentIntent` objects for the same order. Webhook reconciliation has a
race condition where a delayed success webhook can set status to `paid` after
the retry scheduler has already initiated a new attempt. Test review (step 5)
and report writing (step 6) remain.

### Last Verified

Static analysis complete through step 4 (2026-04-11 11:40 UTC). No runtime
verification needed for review workflow.

### Next Exact Step

Step 5: review the three test files to identify coverage gaps for the
scenarios documented in the idempotency and edge-case analyses.

### Active Risks / Blockers

The critical idempotency finding should be communicated to the team promptly.
The review will continue, but this finding warrants immediate attention
independent of the review completion.

### Required Reads Before Resuming

- Working notes from steps 1-4 in `artifacts/rv_payment_retry/working-notes.md`
- `tests/payments/processor.test.ts` (next file to review)

### Proposed Spec Changes

None (review workflow does not propose spec changes; findings go into the
report).

---

## Run-Log Entries

### Entry 1

- Timestamp: 2026-04-11 10:15 UTC
- Actor: agent
- Planned Step: Analyze idempotency key generation in `processor.ts`
- Action Taken: Read `src/payments/processor.ts`. Found idempotency key on
  line 47: `` `payment_${orderId}_${attemptNumber}` ``. This means attempt 1
  and attempt 2 send different idempotency keys to Stripe, so Stripe treats
  them as separate payment intents. If attempt 1 actually succeeded (e.g.,
  network timeout hid the success response), attempt 2 will create a second
  real charge. **Critical finding: double-charging is possible.**
- Result: Critical finding identified
- Files Touched: `artifacts/rv_payment_retry/working-notes.md` (created)
- Verification Run: n/a (static analysis)
- Criteria Impact: criteria 1 met -- double-charging confirmed possible
- Blocker or Risk: critical severity finding

### Entry 2

- Timestamp: 2026-04-11 10:55 UTC
- Actor: agent
- Planned Step: Analyze retry scheduler and webhook reconciliation
- Action Taken: Read `retry-scheduler.ts` and `stripe-handler.ts`. Found race
  condition: webhook handler updates payment status to `paid` (line 31 of
  `stripe-handler.ts`) but does not cancel pending retry jobs in BullMQ.
  If a success webhook arrives at T+90s and the first retry fires at T+60s,
  the retry has already created a second payment intent. Additionally, if the
  webhook arrives *during* a retry attempt, there is no lock -- the status
  could flip to `paid` while `processor.ts` is mid-charge, and the charge
  result will overwrite the webhook-set status.
- Result: Race condition finding (high severity)
- Files Touched: `artifacts/rv_payment_retry/working-notes.md`
- Verification Run: n/a (static analysis)
- Criteria Impact: criteria 2 partially met (2 of 4 scenarios analyzed)
- Blocker or Risk: none (findings documented, will continue review)

### Entry 3

- Timestamp: 2026-04-11 11:35 UTC
- Actor: agent
- Planned Step: Map payment state transitions and check remaining edge cases
- Action Taken: Read `payment.entity.ts`. Status enum: `pending`, `processing`,
  `paid`, `failed`, `refunded`. No database constraint prevents `paid -> processing`
  transition (no check in code either). Analyzed remaining edge cases: (a)
  webhook after max retries -- status set to `failed`, then webhook sets to
  `paid`, which is correct but the order fulfillment job may have already
  fired a cancellation email; (b) concurrent retries due to Redis failover --
  BullMQ "at least once" means two workers could process the same retry job,
  each calling Stripe with the same idempotency key (same attempt number), so
  Stripe deduplicates this case correctly. Documented all four scenarios.
- Result: Two additional medium-severity findings
- Files Touched: `artifacts/rv_payment_retry/working-notes.md`
- Verification Run: n/a (static analysis)
- Criteria Impact: criteria 2 fully met (all 4 scenarios analyzed)
- Blocker or Risk: none

---

## Artifacts

| Artifact | Path | Description |
|----------|------|-------------|
| Working notes | `artifacts/rv_payment_retry/working-notes.md` | Running analysis notes from steps 1-4 |
| State transition map | `artifacts/rv_payment_retry/state-transitions.md` | All payment status transitions with legality analysis |
| Findings report (draft) | `artifacts/rv_payment_retry/review-findings.md` | Partial -- will be completed after step 5-6 |

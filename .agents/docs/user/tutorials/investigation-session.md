# Investigation Session Tutorial

This walkthrough shows how to use the two-session pattern to investigate a production performance regression. The user describes symptoms and prior findings; the agent refines the request into a structured investigation workflow; a second session executes the investigation and reports conclusions.

---

## Session 1: Refine the Investigation

### Step 1 --- The User Describes the Problem

> I need help investigating an API latency regression. Over the past two weeks our p95 response time on two endpoints went from about 200 ms to 800 ms. It seems to have started roughly after the deployment we did two Mondays ago (March 30).
>
> The affected endpoints are `/api/v2/search` and `/api/v2/recommendations`. Other endpoints like `/api/v2/users` and `/api/v2/catalog` look normal.
>
> I've already checked the obvious things. The database dashboards show no change in query latency or connection pool usage. Traffic volume is flat --- there's no spike in request rate. So I don't think this is a load or database problem, but I'm stuck on what else it could be.
>
> Can you turn this into an investigation workflow so we can track it properly?

### Step 2 --- The Agent Asks Clarifying Questions

The agent reads the request and asks follow-up questions before building the dossier.

> **Agent:** A few things I'd like to clarify before I build the dossier:
>
> 1. **What changed in the March 30 deployment?** Was it a dependency update, a feature change, an infrastructure change, or a combination? If there's a PR or deployment log I can reference, that would help narrow the search.
>
> 2. **Do you have APM traces available?** If you're using Datadog, New Relic, or similar, I can look at span-level breakdowns to see where the extra 600 ms is being spent. What's the tracing setup?
>
> 3. **Is the degradation constant or intermittent?** Does every request to `/search` take ~800 ms, or is it bursty --- some requests are fast and outliers pull the p95 up?
>
> 4. **What evidence would be sufficient for you to declare root cause found?** For instance, would a flame graph showing the slow code path be enough, or do you need a fix-and-reverify cycle before you're satisfied?

### Step 3 --- The User Responds

> Good questions.
>
> 1. The March 30 deployment had two things: we upgraded the `searchcore` library from 3.1.2 to 3.4.0 (which changed how query plans are built), and we added a new feature flag evaluation step in the request middleware. The PR is #1847.
>
> 2. We use Datadog APM. Traces are available for both endpoints. I can see spans but I haven't had time to dig through them in detail.
>
> 3. It looks pretty constant. Almost every request is slower, not just outliers. The p50 went from 120 ms to about 500 ms, and p95 from 200 ms to 800 ms.
>
> 4. A flame graph or span breakdown showing where the time is being spent would be enough for me to call it identified. I don't need you to fix it --- just find it and document the evidence so I can assign the fix to the right team.

### Step 4 --- The Agent Produces the Refined Dossier

The agent creates workflow directory `.agents/workflows/draft/iv_api_latency/` containing the following `dossier.md`:

> **Metadata**
> - Workflow ID: `iv_api_latency`
> - Workflow Type: investigation
> - Lifecycle State: draft
> - Owner: (user)
> - Intended Write Scope: investigation notes and measurement scripts only; no production code changes
> - Dependencies: none
>
> **Objective**
>
> Identify the root cause of the p95 latency regression on `/api/v2/search` and `/api/v2/recommendations` that began after the March 30 deployment.
>
> **Background / Context**
>
> p95 rose from ~200 ms to ~800 ms; p50 from ~120 ms to ~500 ms. The degradation is constant, not intermittent. Two changes shipped in the March 30 deploy (PR #1847): an upgrade of `searchcore` from 3.1.2 to 3.4.0, and the addition of a feature-flag evaluation step in request middleware. Database and traffic volume have been ruled out.
>
> **Acceptance Criteria**
> 1. The investigation identifies which of the two March 30 changes (or their interaction) accounts for the majority of the latency increase.
> 2. Evidence is documented: span-level Datadog traces or profiling output showing where the added time is spent.
> 3. A brief report summarizes the finding and recommends a next action (revert, patch, or deeper analysis).
>
> **Failure Policy:** `best_effort` --- if a precise single root cause cannot be isolated, document the narrowed-down candidates with supporting evidence and recommend the next diagnostic step.
>
> **Scope**
> - Analyze Datadog APM traces for `/api/v2/search` and `/api/v2/recommendations`.
> - Compare span timings before and after March 30.
> - Inspect the `searchcore` 3.1.2-to-3.4.0 changelog and diff for query-plan changes.
> - Inspect the feature-flag middleware added in PR #1847.
> - Run local profiling if needed to reproduce the timing difference.
>
> **Non-Goals**
> - Fixing the regression (out of scope; findings will be handed to the owning team).
> - Investigating endpoints that are not affected.
> - Performance tuning unrelated to this regression.
>
> **Plan of Record**
> 1. Pull Datadog traces for both endpoints, comparing a week before March 30 to the past week.
> 2. Identify which spans grew and by how much.
> 3. Correlate the slow spans to the `searchcore` upgrade or the feature-flag middleware.
> 4. If ambiguous, isolate each change locally (disable feature flags, pin `searchcore` to 3.1.2) and measure.
> 5. Document findings in `artifacts.md` with trace screenshots or profiling data.
> 6. Write a summary with root cause assessment and recommended next action.

### Step 5 --- The User Reviews and Approves

The user reads the dossier and confirms:

> This looks right. The plan of record makes sense --- start with traces, then isolate if needed. Approved.

The agent moves the packet from `draft/iv_api_latency/` to `active/iv_api_latency/` and writes the initial `handoff.md`:

> **Current Status:** Dossier approved. Investigation has not started.
>
> **Next Exact Step:** Pull Datadog APM traces for `/api/v2/search` for one week before and one week after March 30. Identify which spans changed.
>
> **Active Risks / Blockers:** None.
>
> **Required Reads Before Resuming:** `dossier.md` in this packet.

---

## Session 2: Execute the Investigation

### Step 6 --- The User Starts the Execution Session

> Resume the `iv_api_latency` investigation workflow from its handoff and execute the plan.

### Step 7 --- The Agent Picks Up from Handoff

The agent reads `handoff.md`, then `dossier.md`, and begins execution. It works through the plan of record, recording each step in `run-log.md`:

1. **Trace comparison.** The agent pulls Datadog trace data for both endpoints. It finds that a span called `searchcore.build_query_plan` grew from an average of 40 ms to 320 ms after March 30. All other spans are within 10% of their prior values.

2. **Changelog inspection.** The agent reads the `searchcore` 3.4.0 changelog and finds that query plan construction was refactored to support nested boolean filters. The new code path calls a `validate_plan_consistency` function on every query, which was not present in 3.1.2.

3. **Feature-flag middleware.** The agent inspects the middleware added in PR #1847. It adds ~5 ms per request for the flag evaluation call. This is a minor contributor but not the primary cause.

4. **Local isolation test.** The agent pins `searchcore` back to 3.1.2 in a local environment and measures `/api/v2/search` latency: p95 drops from 790 ms to 215 ms, confirming the library upgrade as the dominant cause.

5. **Evidence capture.** The agent saves the trace comparison, the changelog excerpt, and the local benchmark results to `artifacts.md`.

### Step 8 --- The Agent Updates Handoff and Reports

The agent writes the final `handoff.md`:

> **Current Status:** Investigation complete. Root cause identified.
>
> **Last Verified:** Local isolation test confirmed `searchcore` 3.4.0 `validate_plan_consistency` is the dominant cause (adds ~280 ms to query plan construction).
>
> **Next Exact Step:** None; awaiting user review. Recommend handing findings to the search team for a targeted fix or version pin.
>
> **Active Risks / Blockers:** None.

The agent provides a summary to the user:

> **Root cause:** The `searchcore` 3.1.2-to-3.4.0 upgrade introduced a `validate_plan_consistency` call that runs on every query plan construction. This adds approximately 280 ms per request to `/api/v2/search` and `/api/v2/recommendations`, which accounts for the bulk of the p95 regression from 200 ms to 800 ms.
>
> **Supporting evidence:**
> - Datadog span comparison (before/after March 30) saved to `artifacts.md`.
> - `searchcore` 3.4.0 changelog excerpt identifying the new validation step.
> - Local benchmark: pinning to 3.1.2 restored p95 to ~215 ms.
>
> **Minor contributor:** The feature-flag middleware adds ~5 ms per request. Not significant but worth noting.
>
> **Recommended next action:** File an issue with the search team to either optimize `validate_plan_consistency`, make it configurable, or evaluate whether `searchcore` 3.2.x includes the needed features without the validation overhead.

### Step 9 --- What the User Reviews

At the end of the investigation, the user typically reads:

- **The summary above** --- the root cause and recommendation.
- **`artifacts.md`** --- to see the trace comparisons and benchmark data if they want supporting detail.
- **`dossier.md`** --- only if they want to confirm the acceptance criteria were met.

The user does not usually need to read `run-log.md` unless they want to understand the full sequence of steps the agent took. The workflow can now be moved to `done/iv_api_latency/` or kept active if follow-up work is needed.

# Performance Session Tutorial

This walkthrough shows how to use the two-session pattern for a performance measurement workflow. The user wants to quantify whether a new caching layer actually improves API load times, with evidence suitable for a technical design review. The agent refines the request into a structured performance packet, and a second session executes the measurements and produces a report.

---

## Session 1: Refine the Performance Measurement

### Step 1 --- The User Describes What They Need

> I added a Redis caching layer to the `/dashboard/stats` endpoint last week and I need to measure whether it actually helps. The change is on a feature branch (`feature/dashboard-cache`) and hasn't been merged yet.
>
> My expectation is that cached hits should be 2-3x faster than the current uncached path. The endpoint aggregates data from three database tables and currently takes about 1.2 seconds under realistic load. With the cache warm, I'm hoping for 400-600 ms.
>
> I need a proper before/after comparison with realistic data volumes, not just a quick curl. This evidence is going into my technical design review next Thursday, so it needs to be methodical enough that the team won't question the methodology.
>
> Can you set this up as a performance workflow?

### Step 2 --- The Agent Asks Clarifying Questions

> **Agent:** Happy to set this up. A few things to nail down for the dossier:
>
> 1. **What constitutes "realistic data volumes"?** How many records are in the three tables in production? Should I seed a test database with a similar count, or is there already a staging environment with production-scale data?
>
> 2. **How many iterations per measurement?** A single request tells you nothing about variance. Would 50 iterations per scenario be enough to get stable p50/p95/p99 numbers, or does your team expect more?
>
> 3. **Should cold-start vs warm-cache be measured separately?** The first request after a deploy or cache flush will always miss. Do you want three scenarios (no cache / cold cache / warm cache), or just two (no cache / warm cache)?
>
> 4. **What methodology does your team consider acceptable for design reviews?** For example, do they expect a specific benchmarking tool (like `k6`, `wrk`, or `autocannon`), or is a scripted measurement with documented methodology sufficient? And should the comparison be on the same machine under the same conditions, or is it okay to compare the feature branch against main on separate runs?

### Step 3 --- The User Responds

> 1. Production has about 200k users, 1.5M activity records, and 800k dashboard events across the three tables. We have a staging database seeded with roughly that volume. Use the staging DB --- it's configured in `config/staging.env`.
>
> 2. 50 iterations per scenario is fine. The team cares about p50 and p95. If you can also show standard deviation, that would help.
>
> 3. Good call --- let's do three scenarios: baseline (no cache, running against `main`), cold cache (first request on the feature branch after cache flush), and warm cache (subsequent requests on the feature branch). The cold-cache number is important because it tells us the worst-case regression risk.
>
> 4. The team is pragmatic. A scripted measurement using `autocannon` or even a simple loop with `curl` timing is fine, as long as the methodology is documented: same machine, same data, sequential runs, and the results are reproducible. Both branches should be measured on the same machine in the same session.

### Step 4 --- The Agent Produces the Refined Dossier

The agent creates `.agents/workflows/draft/pf_dashboard_cache/` with the following `dossier.md`:

> **Metadata**
> - Workflow ID: `pf_dashboard_cache`
> - Workflow Type: performance
> - Lifecycle State: draft
> - Owner: (user)
> - Intended Write Scope: benchmark scripts, measurement reports, and configuration notes; no production code changes
>
> **Objective**
>
> Quantify the performance impact of the Redis caching layer on `/dashboard/stats` with a before/after comparison suitable for technical design review.
>
> **Background / Context**
>
> The endpoint aggregates data from three tables (~200k users, ~1.5M activity records, ~800k dashboard events). Current uncached response time is ~1.2 s. The caching layer is on `feature/dashboard-cache` and has not been merged. Expected improvement on cache hits is 2-3x (target: 400-600 ms). Staging database has production-scale data via `config/staging.env`.
>
> **Acceptance Criteria**
> 1. Baseline measurements (no cache, `main` branch): 50 iterations with p50, p95, and standard deviation.
> 2. Cold-cache measurements (`feature/dashboard-cache`, cache flushed): 50 iterations, same metrics.
> 3. Warm-cache measurements (`feature/dashboard-cache`, cache primed): 50 iterations, same metrics.
> 4. All three scenarios run on the same machine in the same session against the staging database.
> 5. Methodology documented: tool, iteration count, data volume, machine specs.
> 6. Summary comparison table with percentage change across scenarios.
>
> **Failure Policy:** `stop` --- if measurements cannot be completed reliably (e.g., staging database unavailable, extreme variance suggesting an environmental problem), stop and report rather than producing unreliable numbers.
>
> **Scope**
> - Create a benchmark script targeting `GET /dashboard/stats`.
> - Run against `main` (baseline), then `feature/dashboard-cache` with cache flushed (cold) and primed (warm).
> - Collect and format results.
>
> **Non-Goals**
> - Optimizing the caching implementation (measurement only).
> - Benchmarking other endpoints.
> - Load testing with concurrent users (single-client sequential measurement only).
>
> **Plan of Record**
> 1. Write a benchmark script that sends 50 sequential requests and records individual response times.
> 2. Check out `main`, start the server against staging, and run the baseline.
> 3. Check out `feature/dashboard-cache`, flush Redis, run 50 requests (cold cache).
> 4. Without flushing, run another 50 requests (warm cache).
> 5. Compute p50, p95, and standard deviation for each scenario.
> 6. Produce a comparison table, narrative summary, and record everything in `artifacts.md`.

### Step 5 --- The User Reviews and Approves

> This is exactly what I need. One small note: make sure to include the machine specs in the report (CPU, RAM, OS) --- the team always asks. Otherwise, approved.

The agent adds the machine-specs requirement to the methodology section, moves the packet to `active/pf_dashboard_cache/`, and writes the initial `handoff.md`:

> **Current Status:** Dossier approved. Measurements have not started.
>
> **Next Exact Step:** Write the benchmark script, then check out `main` and run the baseline measurement against the staging database.
>
> **Active Risks / Blockers:** None. Verify staging database connectivity before starting measurements.
>
> **Required Reads Before Resuming:** `dossier.md` in this packet.

---

## Session 2: Execute the Measurements

### Step 6 --- The User Starts the Execution Session

> Resume the `pf_dashboard_cache` performance workflow from its handoff and run the measurements.

### Step 7 --- The Agent Picks Up from Handoff

The agent reads `handoff.md`, then `dossier.md`, and begins execution. It works through the plan of record, recording each step in `run-log.md`.

1. **Benchmark script.** The agent writes `scripts/bench_dashboard.sh`, a shell script that calls `curl` 50 times in sequence, records each response time, and computes p50, p95, mean, and standard deviation. The script accepts a label argument for tagging the output.

2. **Machine specs.** The agent records: Apple M2 Pro, 16 GB RAM, macOS 14.3, Node 20.11.0, Redis 7.2.4.

3. **Baseline (main, no cache).** The agent checks out `main`, starts the server with `config/staging.env`, and runs the benchmark. Results:

   | Metric | Value |
   |--------|-------|
   | p50    | 1,180 ms |
   | p95    | 1,410 ms |
   | Std dev | 95 ms |

4. **Cold cache (feature branch, cache flushed).** The agent checks out `feature/dashboard-cache`, starts the server, runs `redis-cli FLUSHDB`, and runs 50 requests. Results:

   | Metric | Value |
   |--------|-------|
   | p50    | 1,240 ms |
   | p95    | 1,520 ms |
   | Std dev | 110 ms |

   The cold-cache scenario is slightly slower than baseline due to the overhead of populating the cache on each miss.

5. **Warm cache (feature branch, cache primed).** Without flushing, the agent runs another 50 requests. Results:

   | Metric | Value |
   |--------|-------|
   | p50    | 390 ms |
   | p95    | 460 ms |
   | Std dev | 35 ms |

### Step 8 --- The Agent Produces the Report

The agent writes a comparison table and narrative to `artifacts.md`:

> **Performance Comparison --- `/dashboard/stats` with Redis Cache**
>
> | Scenario | p50 | p95 | Std Dev | vs Baseline (p50) |
> |----------|-----|-----|---------|-------------------|
> | Baseline (main, no cache) | 1,180 ms | 1,410 ms | 95 ms | --- |
> | Cold cache (feature, flushed) | 1,240 ms | 1,520 ms | 110 ms | +5.1% slower |
> | Warm cache (feature, primed) | 390 ms | 460 ms | 35 ms | 3.0x faster |
>
> **Machine:** Apple M2 Pro, 16 GB RAM, macOS 14.3, Node 20.11.0, Redis 7.2.4
> **Data volume:** ~200k users, ~1.5M activity records, ~800k dashboard events (staging database)
> **Methodology:** 50 sequential single-client requests per scenario, same machine, same session, no concurrent workloads. Benchmark script: `scripts/bench_dashboard.sh`.
>
> **Summary:**
> - Warm-cache performance meets the 2-3x improvement target (3.0x at p50, 3.1x at p95).
> - Cold-cache performance shows a small regression (~5% at p50) due to cache-population overhead. This is expected and affects only the first request after a cache flush or TTL expiry.
> - Variance (standard deviation) dropped significantly with warm cache, indicating more consistent response times.
> - The caching layer achieves its stated goal. The cold-cache penalty is minor and transient.

The agent writes the final `handoff.md`:

> **Current Status:** All three measurement scenarios completed. Comparison report written to `artifacts.md`.
>
> **Last Verified:** Warm-cache p50 of 390 ms confirms the 2-3x improvement target is met (3.0x).
>
> **Next Exact Step:** None; awaiting user review. Report is ready for the Thursday design review.
>
> **Active Risks / Blockers:** None.
>
> **Proposed Spec Changes:** None.

### Step 9 --- What the User Reviews

At the end of the performance workflow, the user typically reads:

- **The comparison table and summary in `artifacts.md`** --- this is the primary deliverable for the design review.
- **The benchmark script** (`scripts/bench_dashboard.sh`) --- to confirm the methodology is sound and reproducible.
- **`dossier.md`** --- only to verify that all six acceptance criteria were met.

The user does not usually need to read `run-log.md` unless they want to see the raw output from each measurement run. The workflow can be moved to `done/pf_dashboard_cache/` once the design review is complete.

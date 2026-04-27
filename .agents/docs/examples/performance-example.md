# Performance Example -- Redis Caching for Dashboard Stats

This example shows a complete workflow packet for measuring the impact of
adding Redis caching to the dashboard statistics endpoint.

---

## Starting Brief

The `GET /api/dashboard/stats` endpoint aggregates data across five tables
(users, orders, products, reviews, inventory) to produce the admin dashboard
summary cards. Under production load (~200 concurrent admin sessions), this
endpoint has a p95 response time of 2.8 seconds, which makes the dashboard
feel sluggish. The data only needs to be fresh within 5 minutes, so caching
is a natural fit.

I have already implemented a Redis-backed cache layer in
`src/cache/stats-cache.service.ts` that wraps the existing
`DashboardStatsService.computeStats()` call. The cache key is
`dashboard:stats:v1`, TTL is 300 seconds, and cache invalidation is handled
by a pub/sub listener on write events. The implementation is on the
`feature/stats-cache` branch but has not been merged.

I need the agent to run a controlled benchmark comparing the uncached (main
branch) and cached (feature branch) behavior. Measurements should cover cold
cache, warm cache, and cache-miss-under-load scenarios. The goal is to
quantify the improvement and confirm there are no regressions in data
correctness.

---

## Dossier

### Metadata

- Workflow ID: pf_dashboard_stats_cache
- Workflow Type: performance
- Lifecycle State: active
- Owner / Current Executor: agent
- Intended Write Scope: `benchmarks/`, `artifacts/pf_dashboard_stats_cache/`
- Dependencies On Other Active Workflows: none

### Objective

Quantify the latency and throughput impact of Redis caching on the
`/api/dashboard/stats` endpoint through controlled, repeatable benchmarks.
Determine whether the improvement justifies merging the `feature/stats-cache`
branch.

### Background / Context

The dashboard stats endpoint joins five tables and runs three aggregate
subqueries. The current uncached p95 under production-like load is 2.8 seconds
(measured via Datadog). The application runs on Node 20 with NestJS 10,
PostgreSQL 15, and Redis 7. The cache implementation uses `ioredis` with
a 300-second TTL and JSON serialization.

The benchmark will use `autocannon` (already a devDependency) to simulate
concurrent load against a local instance backed by Docker Compose services
(PostgreSQL + Redis).

### Contract

The benchmark is complete when baseline (uncached) and treatment (cached)
measurements are captured under identical conditions, with sufficient
iterations to produce stable p50/p95/p99 numbers, and the results are
documented in a reproducible report.

### Acceptance Criteria

1. Baseline measurements captured on `main` branch: p50, p95, p99 latency
   and requests/sec at 50 concurrent connections for 60 seconds.
2. Treatment measurements captured on `feature/stats-cache` branch under
   the same conditions, for three scenarios:
   - Cold cache (first request populates cache)
   - Warm cache (subsequent requests served from cache)
   - Cache miss under load (cache manually flushed mid-benchmark)
3. Data correctness verified: response body from cached endpoint matches
   uncached endpoint byte-for-byte (after JSON normalization).
4. Results documented in `artifacts/pf_dashboard_stats_cache/benchmark-report.md`
   with a comparison table and methodology section.
5. Benchmark scripts committed to `benchmarks/dashboard-stats/` and are
   re-runnable via `make bench-dashboard`.

### Failure Policy

`stop` -- halt if the cached endpoint returns different data than the uncached
endpoint, as this indicates a correctness bug in the cache layer.

### Scope

- Write benchmark scripts in `benchmarks/dashboard-stats/`.
- Add a `bench-dashboard` target to the Makefile.
- Run baseline and treatment benchmarks.
- Capture and document results.

### Non-Goals

- Optimizing the underlying SQL queries (separate workflow).
- Benchmarking other endpoints.
- Testing cache behavior under Redis failover or eviction pressure.
- Profiling memory usage of the cache layer.

### Constraints and Assumptions

- Benchmarks run locally against Docker Compose services, not production.
- The test database is seeded with `make seed` (10k users, 50k orders, 100k
  reviews) to approximate production data volume.
- Each benchmark run uses a fresh Docker Compose environment to eliminate
  cross-run interference.
- `autocannon` v7.x is used for HTTP load generation.

### Dependencies

- Docker Compose stack: `docker compose -f docker-compose.bench.yml up`
- Seed script: `make seed`
- Both `main` and `feature/stats-cache` branches must be available locally.

### Plan of Record

1. Write the benchmark script (`benchmarks/dashboard-stats/run.ts`) using
   autocannon with 50 concurrent connections, 60-second duration.
2. Add the `bench-dashboard` Makefile target.
3. Run baseline on `main`: `docker compose up`, `make seed`, `make bench-dashboard`.
4. Record baseline results.
5. Switch to `feature/stats-cache`, run warm-cache benchmark.
6. Run cold-cache benchmark (flush Redis, then run).
7. Run cache-miss benchmark (flush Redis at T+30s during the run).
8. Verify data correctness: `diff <(curl main) <(curl feature)`.
9. Write the benchmark report.

### Verification Strategy

- Each benchmark run saves raw autocannon JSON output to `artifacts/`.
- Data correctness is verified by comparing JSON responses (step 8).
- Results are considered stable when two consecutive runs produce p95 values
  within 10% of each other.

### References

- Cache implementation: `src/cache/stats-cache.service.ts` (on `feature/stats-cache`)
- Dashboard stats service: `src/dashboard/stats.service.ts`
- Autocannon docs: `https://github.com/mcollina/autocannon`
- Docker Compose bench config: `docker-compose.bench.yml`

### Open Questions

- Should the benchmark include a ramp-up period, or start at full concurrency
  immediately? (Decided: no ramp-up, start at 50 connections immediately, to
  match the worst-case production scenario.)

---

## Handoff Snapshot

### Current Status

Steps 1-6 complete. Benchmark scripts written, Makefile target added, baseline
captured, and warm-cache + cold-cache treatment runs completed. Key finding so
far: warm-cache p95 is 12 ms (vs. baseline 2,840 ms), a 236x improvement.
Cold-cache first request is 3,100 ms (slightly slower than uncached due to
cache-write overhead), but subsequent requests drop to 11 ms. Steps 7-9
(cache-miss-under-load, correctness verification, report) remain.

### Last Verified

Warm-cache benchmark: p50 8 ms, p95 12 ms, p99 18 ms, 4,150 req/sec
(2026-04-11 17:20 UTC).

### Next Exact Step

Step 7: run the cache-miss-under-load benchmark. Start autocannon, then at
T+30s run `redis-cli FLUSHDB` to force a mid-run cache miss, and observe
how latency spikes and recovers.

### Active Risks / Blockers

None.

### Required Reads Before Resuming

- `benchmarks/dashboard-stats/run.ts` (benchmark script)
- `artifacts/pf_dashboard_stats_cache/baseline-raw.json` (baseline numbers)
- `artifacts/pf_dashboard_stats_cache/warm-cache-raw.json` (treatment numbers)

### Proposed Spec Changes

None.

---

## Run-Log Entries

### Entry 1

- Timestamp: 2026-04-11 16:10 UTC
- Actor: agent
- Planned Step: Write benchmark scripts and Makefile target
- Action Taken: Created `benchmarks/dashboard-stats/run.ts` using autocannon
  with configurable duration, connections, and output path. Added
  `bench-dashboard` target to Makefile that starts Docker Compose, waits for
  healthy services, seeds the database, and runs the benchmark.
- Result: success
- Files Touched: `benchmarks/dashboard-stats/run.ts` (created),
  `benchmarks/dashboard-stats/tsconfig.json` (created), `Makefile`
- Verification Run: `make bench-dashboard --dry-run` -- target resolves correctly
- Criteria Impact: criteria 5 met
- Blocker or Risk: none

### Entry 2

- Timestamp: 2026-04-11 16:45 UTC
- Actor: agent
- Planned Step: Capture baseline measurements on `main` branch
- Action Taken: Checked out `main`. Ran `docker compose -f docker-compose.bench.yml up -d`,
  `make seed`, `make bench-dashboard`. Two consecutive runs produced stable
  results (p95 within 4% of each other). Baseline numbers: p50 1,920 ms,
  p95 2,840 ms, p99 3,410 ms, throughput 17.2 req/sec at 50 connections.
- Result: success
- Files Touched: `artifacts/pf_dashboard_stats_cache/baseline-raw.json`
  (created), `artifacts/pf_dashboard_stats_cache/baseline-run2.json` (created)
- Verification Run: two consecutive runs for stability confirmation
- Criteria Impact: criteria 1 met
- Blocker or Risk: none

### Entry 3

- Timestamp: 2026-04-11 17:18 UTC
- Actor: agent
- Planned Step: Capture warm-cache and cold-cache measurements
- Action Taken: Checked out `feature/stats-cache`. Rebuilt and restarted
  Docker Compose. Warm cache: pre-populated cache with a single request,
  then ran benchmark. Cold cache: flushed Redis, ran benchmark (first request
  populates cache, remaining requests hit cache). Results:
  Warm cache: p50 8 ms, p95 12 ms, p99 18 ms, 4,150 req/sec.
  Cold cache: first-request 3,100 ms, then p50 9 ms, p95 13 ms, p99 19 ms,
  4,020 req/sec (averaged over full run including the cold start).
- Result: success
- Files Touched: `artifacts/pf_dashboard_stats_cache/warm-cache-raw.json`
  (created), `artifacts/pf_dashboard_stats_cache/cold-cache-raw.json` (created)
- Verification Run: warm-cache run repeated twice for stability (p95 variance < 8%)
- Criteria Impact: criteria 2 partially met (2 of 3 scenarios captured)
- Blocker or Risk: none

---

## Artifacts

| Artifact | Path | Description |
|----------|------|-------------|
| Benchmark script | `benchmarks/dashboard-stats/run.ts` | Autocannon-based benchmark runner |
| Makefile target | `Makefile` (bench-dashboard target) | Orchestrates Docker, seed, and benchmark |
| Baseline results | `artifacts/pf_dashboard_stats_cache/baseline-raw.json` | Autocannon JSON, main branch, 50 conn / 60s |
| Baseline run 2 | `artifacts/pf_dashboard_stats_cache/baseline-run2.json` | Stability confirmation run |
| Warm-cache results | `artifacts/pf_dashboard_stats_cache/warm-cache-raw.json` | Autocannon JSON, feature branch, warm cache |
| Cold-cache results | `artifacts/pf_dashboard_stats_cache/cold-cache-raw.json` | Autocannon JSON, feature branch, cold start |

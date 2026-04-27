# Investigation Example -- API Response Time Degradation

This example shows a complete workflow packet for investigating increased
response times on the `/api/search` and `/api/recommendations` endpoints.

---

## Starting Brief

Over the past two weeks, our Datadog dashboards show that p95 response times
for `GET /api/search` climbed from 120 ms to 450 ms, and
`GET /api/recommendations` went from 80 ms to 310 ms. Other endpoints are
unaffected. The degradation is gradual, not a cliff -- it started around
March 28 and has been worsening steadily.

No code changes were deployed to those endpoints during that period. The only
infrastructure change was a PostgreSQL minor version upgrade (15.4 to 15.6) on
March 27, but the release notes mention no breaking changes to query planning.
The database host CPU and memory metrics look normal. Connection pool usage in
PgBouncer is at 60% of max.

I need the agent to systematically identify the root cause. The investigation
should produce concrete evidence (query plans, traces, metrics) rather than
speculation. The agent should not make any code or infrastructure changes --
only observe, measure, and report.

---

## Dossier

### Metadata

- Workflow ID: iv_api_latency_regression
- Workflow Type: investigation
- Lifecycle State: active
- Owner / Current Executor: agent
- Intended Write Scope: `artifacts/iv_api_latency_regression/` only
- Dependencies On Other Active Workflows: none

### Objective

Identify the root cause of p95 latency regression on `/api/search` and
`/api/recommendations`, supported by evidence (query plans, profiling data,
or traces). Deliver a findings report with a recommended remediation path.

### Background / Context

Both endpoints query the `products` table (14M rows) and the
`user_interactions` table (220M rows). The search endpoint uses a full-text
`tsvector` index; the recommendations endpoint joins `user_interactions` with
`products` using a score-weighted query. The application is a NestJS service
(`src/api/`) connecting through PgBouncer to a PostgreSQL 15.6 primary with
two read replicas. The ORM is TypeORM 0.3.

The gradual onset suggests this is not a code regression but rather a data-
volume or query-plan issue. The `user_interactions` table grows by ~1.5M rows
per week.

### Contract

The investigation is complete when the root cause is identified with
supporting evidence, or when all reasonable hypotheses have been tested and
documented. A findings report must be delivered regardless of outcome.

### Acceptance Criteria

1. Baseline p95 latency numbers documented for both endpoints (current vs.
   two weeks ago, sourced from Datadog).
2. At least three hypotheses tested with evidence for/against each.
3. Query execution plans (`EXPLAIN ANALYZE`) captured for both endpoints'
   primary queries under current data volume.
4. Root cause identified with confidence level stated (high/medium/low).
5. Findings report written to `artifacts/iv_api_latency_regression/findings.md`
   with remediation recommendations.

### Failure Policy

`best_effort` -- if the root cause cannot be definitively identified,
document what was ruled out and the most likely remaining hypothesis.

### Scope

- Query Datadog API for historical latency metrics.
- Run `EXPLAIN ANALYZE` on the primary queries for both endpoints.
- Check PostgreSQL `pg_stat_user_tables` for sequential scan counts and
  index usage on `products` and `user_interactions`.
- Check `pg_stat_user_indexes` for index bloat indicators.
- Review PgBouncer connection pool stats.
- Produce a findings report.

### Non-Goals

- Implementing any fix or optimization.
- Modifying database schema, indexes, or application code.
- Investigating endpoints other than `/api/search` and `/api/recommendations`.

### Constraints and Assumptions

- Read-only access to production database via read replica.
- Datadog API access via `DD_API_KEY` and `DD_APP_KEY` env vars.
- All queries must be run against the read replica, never the primary.
- Investigation must not generate load that impacts production traffic.

### Dependencies

- Read replica connection string in `.env.investigation`.
- Datadog API credentials for metric queries.
- `psql` client available locally.

### Plan of Record

1. Pull p95 latency data from Datadog for both endpoints over the past 30 days.
2. Capture `EXPLAIN ANALYZE` output for the search endpoint's primary query.
3. Capture `EXPLAIN ANALYZE` output for the recommendations endpoint's
   primary query.
4. Query `pg_stat_user_tables` for `products` and `user_interactions` to check
   seq scan ratios and dead tuple counts.
5. Query `pg_stat_user_indexes` for the `tsvector` index and the
   `user_interactions` join index to check size and bloat.
6. Check if PostgreSQL 15.6 changed the query planner behavior for the
   specific query patterns used.
7. Synthesize findings and write the report.

### Verification Strategy

- Each data-gathering step produces a saved artifact (query output, metric
  screenshot, or JSON export).
- The findings report must reference specific artifacts as evidence for each
  conclusion.

### References

- Datadog dashboard: "API Latency Overview" (team: backend)
- PostgreSQL 15.6 release notes: `https://www.postgresql.org/docs/15/release-15-6.html`
- Schema reference: `docs/database/schema.md`
- PgBouncer config: `infra/pgbouncer/pgbouncer.ini`

### Open Questions

- Has the `user_interactions` table been `VACUUM ANALYZE`-d recently? (Will
  check via `pg_stat_user_tables.last_autovacuum`.)

---

## Handoff Snapshot

### Current Status

Steps 1-5 complete. Datadog metrics confirm the regression timeline. Query
plans reveal that the `user_interactions` join index is being partially
bypassed -- the planner is choosing a bitmap heap scan instead of an index-only
scan on the recommendations query. The index on
`(user_id, product_id, score)` has grown to 18 GB with 34% bloat. Dead tuple
count on `user_interactions` is 12M (last autovacuum was 9 days ago).
Step 6-7 remain.

### Last Verified

`EXPLAIN ANALYZE` on recommendations query shows bitmap heap scan cost of
380 ms vs. expected index-only scan cost of ~60 ms (2026-04-11 15:45 UTC).

### Next Exact Step

Step 6: check whether PostgreSQL 15.6 changed cost estimation for bitmap
heap scans vs. index-only scans, and whether a `REINDEX` or `VACUUM FULL`
on the bloated index would restore the original plan.

### Active Risks / Blockers

None, but a `REINDEX` on the 18 GB index would require a maintenance window
and is outside the scope of this investigation (implementation requires
separate approval).

### Required Reads Before Resuming

- `artifacts/iv_api_latency_regression/explain-recommendations.txt`
- `artifacts/iv_api_latency_regression/pg-stat-indexes.txt`
- `artifacts/iv_api_latency_regression/datadog-latency-30d.json`

### Proposed Spec Changes

None.

---

## Run-Log Entries

### Entry 1

- Timestamp: 2026-04-11 14:00 UTC
- Actor: agent
- Planned Step: Pull Datadog latency metrics for 30-day window
- Action Taken: Queried Datadog API for `trace.express.request.duration.p95`
  filtered by `resource_name:/api/search` and `resource_name:/api/recommendations`
  over 2026-03-12 to 2026-04-11. Exported JSON and generated a summary table.
- Result: Confirmed regression start date as March 28. Search p95: 118 ms
  to 447 ms. Recommendations p95: 82 ms to 312 ms.
- Files Touched: `artifacts/iv_api_latency_regression/datadog-latency-30d.json`
  (created), `artifacts/iv_api_latency_regression/latency-summary.md` (created)
- Verification Run: n/a (data collection)
- Criteria Impact: criteria 1 met
- Blocker or Risk: none

### Entry 2

- Timestamp: 2026-04-11 14:35 UTC
- Actor: agent
- Planned Step: Capture EXPLAIN ANALYZE for both endpoints' queries
- Action Taken: Connected to read replica. Ran `EXPLAIN (ANALYZE, BUFFERS,
  FORMAT TEXT)` for the search full-text query and the recommendations join
  query. Search query uses index scan on `products_tsv_idx` (normal).
  Recommendations query uses bitmap heap scan on `user_interactions_score_idx`
  instead of expected index-only scan. Bitmap heap scan execution time: 380 ms.
- Result: Recommendations query plan anomaly identified
- Files Touched: `artifacts/iv_api_latency_regression/explain-search.txt`
  (created), `artifacts/iv_api_latency_regression/explain-recommendations.txt`
  (created)
- Verification Run: n/a (data collection)
- Criteria Impact: criteria 2 partially met (hypothesis: index bloat), criteria 3 met
- Blocker or Risk: none

### Entry 3

- Timestamp: 2026-04-11 15:40 UTC
- Actor: agent
- Planned Step: Check table and index statistics for bloat and vacuum status
- Action Taken: Queried `pg_stat_user_tables` and `pg_stat_user_indexes`.
  `user_interactions`: 12.1M dead tuples, last autovacuum 9 days ago
  (2026-04-02). Index `user_interactions_score_idx`: 18.2 GB on disk,
  estimated live data 12.0 GB (34% bloat). The planner switches from
  index-only to bitmap heap scan when the visibility map is stale (many
  dead tuples force heap fetches). This explains both endpoints' degradation
  since both join through `user_interactions`.
- Result: Root cause identified -- index bloat + stale visibility map due to
  missed autovacuum on high-churn table
- Files Touched: `artifacts/iv_api_latency_regression/pg-stat-tables.txt`
  (created), `artifacts/iv_api_latency_regression/pg-stat-indexes.txt` (created)
- Verification Run: n/a (data collection)
- Criteria Impact: criteria 2 progressing (2 hypotheses tested), criteria 4
  partially met (high confidence, pending planner-version check)
- Blocker or Risk: remediation (REINDEX + VACUUM) requires ops approval

---

## Artifacts

| Artifact | Path | Description |
|----------|------|-------------|
| Datadog export | `artifacts/iv_api_latency_regression/datadog-latency-30d.json` | 30-day p95 latency for both endpoints |
| Latency summary | `artifacts/iv_api_latency_regression/latency-summary.md` | Table comparing before/after latency |
| Search EXPLAIN | `artifacts/iv_api_latency_regression/explain-search.txt` | Query plan for search endpoint |
| Recommendations EXPLAIN | `artifacts/iv_api_latency_regression/explain-recommendations.txt` | Query plan showing bitmap heap scan |
| Table stats | `artifacts/iv_api_latency_regression/pg-stat-tables.txt` | Dead tuples, autovacuum timestamps |
| Index stats | `artifacts/iv_api_latency_regression/pg-stat-indexes.txt` | Index sizes and bloat estimates |

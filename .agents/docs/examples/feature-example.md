# Feature Example -- CSV Export for Admin Dashboard

This example shows a complete workflow packet for adding a CSV export
capability to the admin dashboard's completed-reports view.

---

## Starting Brief

The admin dashboard at `/admin/reports` lists completed assessment reports in a
paginated table. Admins currently have no way to export this data; they
copy-paste rows into spreadsheets manually, which is error-prone and slow when
dealing with hundreds of reports per quarter.

I want a "Download CSV" button in the top-right of the reports table that
exports all completed reports matching the current filter criteria (date range,
department, status). The CSV should include these columns: Report ID, Title,
Department, Completed Date, Assessor, Score, and Recommendation Summary. The
backend already has a `GET /api/admin/reports` endpoint that returns paginated
JSON; I need a companion endpoint that streams CSV.

The frontend is React 18 with TanStack Table. The backend is a NestJS 10
application using TypeORM against PostgreSQL. The test suite uses Vitest for
the frontend and Jest + Supertest for the backend. CI runs both suites via
`make test`.

---

## Dossier

### Metadata

- Workflow ID: ft_csv_export_reports
- Workflow Type: feature
- Lifecycle State: active
- Owner / Current Executor: agent
- Intended Write Scope: `src/api/admin/`, `src/frontend/admin/`, `tests/`
- Dependencies On Other Active Workflows: none

### Objective

Ship a CSV export feature for completed reports on the admin dashboard,
covering both the backend streaming endpoint and the frontend download trigger.

### Background / Context

The existing `GET /api/admin/reports` endpoint accepts `startDate`, `endDate`,
`department`, and `status` query parameters and returns paginated JSON. The
frontend renders this data using `<ReportsTable>` in
`src/frontend/admin/pages/ReportsPage.tsx`. There is no existing export
functionality anywhere in the application.

### Contract

The feature is complete when an admin can click a button, receive a `.csv`
file whose rows match the active filter, and whose columns match the agreed
schema. The download must work for result sets up to 50,000 rows without
timing out.

### Acceptance Criteria

1. `GET /api/admin/reports/export?format=csv` returns `Content-Type: text/csv`
   with `Content-Disposition: attachment; filename="reports-<date>.csv"`.
2. Response streams rows; memory usage stays below 100 MB for 50k rows.
3. CSV columns: Report ID, Title, Department, Completed Date, Assessor,
   Score, Recommendation Summary.
4. The "Download CSV" button appears in `ReportsPage` and passes current
   filter state as query parameters.
5. Button is disabled while the download is in progress (no double-clicks).
6. Backend integration tests verify 200 response, correct headers, and
   parseable CSV body for a seeded dataset.
7. Frontend component test verifies button renders and triggers fetch.

### Failure Policy

`stop` -- halt if the streaming endpoint cannot serve 50k rows within the
30-second gateway timeout, and document the bottleneck for the user.

### Scope

- Create `src/api/admin/reports-export.controller.ts` with the CSV endpoint.
- Create `src/api/admin/csv-serializer.service.ts` for row-by-row streaming.
- Add the "Download CSV" button to `src/frontend/admin/pages/ReportsPage.tsx`.
- Create `src/frontend/admin/hooks/useExportCsv.ts` for download logic.
- Write backend and frontend tests.

### Non-Goals

- PDF export or any format other than CSV.
- Scheduled or emailed exports.
- Export of non-completed (draft/in-progress) reports.

### Constraints and Assumptions

- NestJS 10, TypeORM 0.3, PostgreSQL 15.
- React 18, TanStack Table v8, Vite 5.
- The existing reports query is already optimized with appropriate indexes.
- No new npm packages for CSV generation; use Node streams and manual
  escaping (the columns contain no nested commas or quotes).

### Dependencies

- The seeded test database (`make seed`) must include at least 100 completed
  reports for meaningful integration tests.
- The existing `ReportsPage` component must be stable (no concurrent PRs
  modifying it).

### Plan of Record

1. Create `csv-serializer.service.ts` with a `serializeRow` method and a
   `streamQuery` method that accepts a TypeORM `QueryBuilder`.
2. Create `reports-export.controller.ts` with `GET /export?format=csv`.
3. Write backend integration tests in `tests/api/admin/reports-export.spec.ts`.
4. Run `make test-backend` and confirm all tests pass.
5. Create `useExportCsv.ts` hook in the frontend.
6. Add the "Download CSV" button to `ReportsPage.tsx`.
7. Write frontend component test in `tests/frontend/admin/ReportsPage.test.tsx`.
8. Run `make test` (full suite) and confirm pass.

### Verification Strategy

- After step 3: `make test-backend` must pass with the new export tests.
- After step 7: `make test` (full suite) must pass.
- Manual smoke: seed 50k rows via `make seed-large`, hit the endpoint with
  `curl`, confirm file size and row count match.

### References

- Existing reports endpoint: `src/api/admin/reports.controller.ts`
- Frontend reports page: `src/frontend/admin/pages/ReportsPage.tsx`
- Admin API spec: `docs/api/admin-endpoints.yaml`

### Open Questions

- Should the CSV include a header row with column names? (Assumed yes -- standard
  practice. Will confirm with user if needed.)

---

## Handoff Snapshot

### Current Status

Backend complete (steps 1-4 done). The CSV streaming endpoint works and passes
integration tests. Frontend work (steps 5-8) has not started.

### Last Verified

`make test-backend` -- 134/134 passing including 6 new export tests
(2026-04-11 16:10 UTC).

### Next Exact Step

Step 5: create `src/frontend/admin/hooks/useExportCsv.ts` that constructs the
export URL from current filter state and triggers a browser download via a
hidden anchor element.

### Active Risks / Blockers

None.

### Required Reads Before Resuming

- `src/api/admin/reports-export.controller.ts` (endpoint contract)
- `src/frontend/admin/pages/ReportsPage.tsx` (where the button will go)
- `src/frontend/admin/hooks/useReports.ts` (existing filter state shape)

### Proposed Spec Changes

None.

---

## Run-Log Entries

### Entry 1

- Timestamp: 2026-04-11 14:55 UTC
- Actor: agent
- Planned Step: Create CSV serializer service
- Action Taken: Created `src/api/admin/csv-serializer.service.ts` with
  `serializeRow` (escapes fields, joins with commas) and `streamQuery`
  (accepts a TypeORM `SelectQueryBuilder`, streams rows via `stream()`).
- Result: success
- Files Touched: `src/api/admin/csv-serializer.service.ts` (created)
- Verification Run: `npx tsc --noEmit` -- zero errors
- Criteria Impact: prerequisite for criteria 1-3
- Blocker or Risk: none

### Entry 2

- Timestamp: 2026-04-11 15:30 UTC
- Actor: agent
- Planned Step: Create export controller and write integration tests
- Action Taken: Created `reports-export.controller.ts` wired to
  `CsvSerializerService`. Registered route in `AdminModule`. Wrote 6
  integration tests covering: 200 with correct headers, CSV body parsing,
  filter passthrough, empty result set, date-range boundary, and large
  result set (1000 rows).
- Result: success
- Files Touched: `src/api/admin/reports-export.controller.ts` (created),
  `src/api/admin/admin.module.ts`, `tests/api/admin/reports-export.spec.ts`
  (created)
- Verification Run: `make test-backend` -- 134/134 passing
- Criteria Impact: criteria 1, 2, 3, 6 met
- Blocker or Risk: none

### Entry 3

- Timestamp: 2026-04-11 16:08 UTC
- Actor: agent
- Planned Step: Verify streaming memory behavior with 50k rows
- Action Taken: Ran `make seed-large` (50k completed reports). Hit endpoint
  with `curl -o /tmp/export.csv`. Monitored RSS via `ps`. Peak memory was
  62 MB. Row count in output file: 50,001 (header + 50k data rows). Response
  time: 4.2 seconds.
- Result: success
- Files Touched: none (verification only)
- Verification Run: manual curl + ps monitoring
- Criteria Impact: criteria 2 confirmed (62 MB < 100 MB limit)
- Blocker or Risk: none

---

## Artifacts

| Artifact | Path | Description |
|----------|------|-------------|
| CSV serializer | `src/api/admin/csv-serializer.service.ts` | Streaming CSV row serializer |
| Export controller | `src/api/admin/reports-export.controller.ts` | CSV export endpoint |
| Backend test results | `artifacts/ft_csv_export_reports/backend-tests.txt` | Jest output, 134/134 pass |
| Memory profile | `artifacts/ft_csv_export_reports/memory-50k-export.txt` | RSS trace during 50k-row export (peak 62 MB) |
| Sample CSV | `artifacts/ft_csv_export_reports/sample-export.csv` | First 20 rows of a test export |

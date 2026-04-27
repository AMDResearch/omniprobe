# Tutorial: Feature Session -- CSV Export for the Admin Dashboard

This walkthrough follows the two-session lifecycle for a feature workflow.
A developer adds CSV export to an admin dashboard, gated behind a feature flag.

---

## Session 1: Refine the Request

The user describes the feature and invokes `workflow-refine`.

> Our admin dashboard at `/admin/reports` has three report pages -- User
> Activity, Revenue Summary, and Error Log -- but there is no way to
> download the data. I need a CSV export button on each page so admins can
> download the currently displayed report.
>
> Constraints: only `admin`-role users should see the button or access the
> endpoint. The filename must include a timestamp (like
> `user-activity-2026-04-12.csv`). Our user display names include non-ASCII
> characters, so the CSV must be UTF-8 with a BOM for Excel compatibility.
> I want the feature behind our existing `FeatureFlags` service, gated on a
> flag called `admin_csv_export`. When the flag is off, the button should not
> render and the endpoint should return 404.
>
> Use `workflow-refine` to turn this into a feature workflow.

The agent checks the dossier template, `pm-index.md`, and
`active-workflows.md`, then asks five questions in one batch.

> 1. **Column ordering.** Should CSV columns match the on-screen order? The
>    User Activity table shows "Name, Email, Last Login, Actions" -- should
>    CSV include the "Actions" column?
> 2. **Large datasets.** Revenue Summary can have tens of thousands of rows.
>    Export the current page or the full dataset? Any row-count cap?
> 3. **File naming.** Date-only or include time? Fixed slug or derived from
>    the report title?
> 4. **Streaming vs buffering.** Stream the response for lower memory, or
>    buffer the whole file first?
> 5. **Empty reports.** If a report has zero rows, produce a headers-only CSV
>    or show a "no data" message and skip the download?

> 1. Match on-screen order. Drop "Actions" -- it is just UI buttons.
> 2. Full unfiltered dataset. Cap at 50,000 rows with a warning if hit.
> 3. Date-only. Fixed slugs: `user-activity`, `revenue-summary`, `error-log`.
> 4. Stream it. Revenue Summary is too large to buffer.
> 5. Headers-only CSV. That is actually useful for automated consumers.

The agent presents the refined dossier.

> **Workflow ID:** `ft_admin-csv-export` | **Type:** Feature
>
> **Objective:** Add CSV export to the three admin report pages, gated behind
> the `admin_csv_export` feature flag.
>
> **Acceptance Criteria:** "Download CSV" button visible only to `admin` users
> when flag is on. File named `<slug>-YYYY-MM-DD.csv`. Columns match screen
> order minus "Actions." UTF-8 with BOM. Full unfiltered dataset, capped at
> 50k rows with truncation indicator. Streamed response. Empty reports
> produce headers-only CSV. Flag off: button hidden, endpoint returns 404.
> Existing tests pass. New tests cover auth, flag gating, CSV content,
> unicode, empty case, and row cap.
>
> **Scope:** `src/routes/admin/export.ts` (new), `src/services/csv-serializer.ts`
> (new), `src/components/admin/ReportToolbar.tsx`, plus new test files.
>
> **Non-Goals:** Scheduled/automated exports. Formats other than CSV. Changing
> report query logic. Admin-configurable columns or limits.
>
> **Failure Policy:** `stop` if streaming causes timeouts in test environment.
>
> **Plan of Record:** (1) Create `csv-serializer.ts` with streaming BOM writer
> and tests. (2) Create export endpoint with auth/flag guards and tests.
> (3) Add toolbar button conditioned on role and flag. (4) Integration test
> for all three reports. (5) Verify flag-off path. (6) Final test run.

The user approves and the agent creates the packet at
`.agents/workflows/active/ft_admin-csv-export/`.

---

## Handoff State After Session 1

```
Current Status: Packet created. Dossier approved. No code changes.
Next Exact Step: Create src/services/csv-serializer.ts with streaming
  UTF-8+BOM writer, column ordering, unicode handling, and 50k-row cap.
  Write unit tests alongside.
Active Risks: Streaming may need tuning for very large Revenue Summary.
Required Reads: dossier.md; ReportToolbar.tsx; feature-flags.ts.
```

---

## Session 2: Resume and Execute

> Use `workflow-resume` and continue `ft_admin-csv-export` from handoff.

The agent reads `handoff.md`, then `dossier.md`, checks
`active-workflows.md` for conflicts, reads `ReportToolbar.tsx` and
`feature-flags.ts`, and appends a session-start entry to `run-log.md`.

The agent works through the plan:

1. **CSV serializer.** Creates `csv-serializer.ts` as a `Transform` stream
   that prepends a UTF-8 BOM, escapes fields with commas/quotes, and
   enforces the 50k-row cap. Tests cover ASCII, accented and CJK
   characters, fields with commas, empty data, and cap truncation. All pass.

2. **Export endpoint.** Creates `GET /admin/reports/:slug/export` in
   `export.ts` with auth guard, flag check (404 if off), streaming CSV
   response, and `Content-Disposition` header. Tests cover 403 on non-admin,
   404 on flag-off, successful download with content verification, and row
   cap. All pass.

3. **Toolbar button.** Adds "Download CSV" to `ReportToolbar.tsx`, rendered
   only for `admin` role when flag is on. Component tests verify both
   conditions. All pass.

4. **Integration.** End-to-end tests for all three reports with flag
   enabled, verifying CSV content. Results recorded in `run-log.md` and
   `artifacts.md`.

5. **Flag-off check.** Confirms button hidden and endpoint returns 404.

6. **Final run.** `npm test` -- 187 tests pass (34 new).

Final handoff:

```
Current Status: Complete. Export endpoint, serializer, and button
  implemented. Flag gating verified both on and off. 34 new tests.
  Suite passes (187/187).
Next Exact Step: None -- ready for human review and closure.
```

---

## What the User Reviews

- **`dossier.md`** -- confirm acceptance criteria were not modified.
- **`handoff.md`** -- final status and test results.
- **`artifacts.md`** -- test evidence.
- **The diff** -- new `csv-serializer.ts`, `export.ts`, changes to
  `ReportToolbar.tsx`, and new test files.
- **Flag behavior** -- optionally toggle the flag in staging.

The feature goes live when the team enables `admin_csv_export` in production.

---
name: pm-bugfix
description: |
  Create or manage a bug-fix workflow packet. Use when the user reports a bug,
  says "fix this bug", or needs a structured workflow for diagnosing and
  resolving a defect. Emphasizes reproduction, root cause analysis, minimal fix,
  and regression testing.
---

# pm-bugfix

## Purpose

Create or manage a bug-fix workflow packet. Bug-fix workflows combine diagnosis with a targeted code change. The emphasis is on reproducing the bug, identifying the root cause, applying a minimal fix, and verifying that the fix resolves the reported behavior without introducing regressions.

## Required Reads

1. `.agents/workflows/dossier-template.md` — packet structure reference.
2. `.agents/state/active-workflows.md` — check for related or overlapping work.
3. `.agents/pm/pm-index.md` — load PM units relevant to the affected area.

## Procedure

1. **Gather the bug report.** Extract from the user's description: the observed behavior, the expected behavior, reproduction steps (if known), and any environmental context (OS, version, config).
2. **Choose the workflow ID.** Use the prefix `bf_` followed by a short slug describing the bug (e.g., `bf_login-timeout-crash`).
3. **Create the packet directory** under `.agents/workflows/draft/bf_<slug>/`.
4. **Write `dossier.md`** using the template. Pay special attention to:
   - **Objective**: State what "fixed" means — the observable behavior change, not just "fix the bug."
   - **Background / Context**: Include the bug report, reproduction steps, and any known constraints (e.g., "only happens on Postgres 15").
   - **Acceptance Criteria**: Must include at minimum:
     - The reported bug no longer reproduces under the stated conditions.
     - Existing tests continue to pass.
     - A regression test exists for the specific bug (when feasible).
   - **Failure Policy**: Typically `stop` — if the root cause cannot be identified, report findings rather than applying a speculative fix.
   - **Plan of Record**: Structure as: (1) reproduce the bug, (2) diagnose root cause, (3) implement fix, (4) add regression test, (5) verify fix and existing tests.
   - **Scope**: Keep tight. A bug fix should not include refactoring, feature additions, or cleanup beyond what is necessary to resolve the bug.
   - **Non-Goals**: Explicitly exclude broader cleanup, performance improvements, or related-but-separate bugs.
   - **Intended Write Scope**: The files expected to change. Keep this minimal.
5. **Write `handoff.md`** with the first step: reproduce the bug.
6. **Write empty `run-log.md` and `artifacts.md`** from the templates.
7. **Update `.agents/state/active-workflows.md`** with the new workflow entry.

## Output

- A complete packet at `.agents/workflows/draft/bf_<slug>/` containing all four files.
- An updated row in `.agents/state/active-workflows.md`.

## Completion Criteria

- The dossier has a clear observable-behavior objective (not just "fix the bug").
- Acceptance criteria include reproduction verification and regression test.
- The plan of record starts with reproduction, not with a fix.
- The intended write scope is stated and minimal.

## Error Handling

- If the user cannot provide reproduction steps, note this as a risk in the dossier and make the first plan step "attempt to reproduce." Set failure policy to `stop` with a note that the workflow may move to `failed` if reproduction is not possible.
- If the bug appears to overlap with an active workflow's write scope, flag it and ask the user whether to coordinate or sequence the work.
- If the bug is actually a feature request in disguise, say so and suggest using `pm-feature` instead.

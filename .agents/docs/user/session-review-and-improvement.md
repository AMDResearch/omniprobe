# Session Review And Improvement

Session review turns work history into process improvements.

## Session Capture

Portable captures live under `.untracked/session-captures/`. Each capture should record the session goal, files touched, commands run, tests run, blockers, and unresolved follow-ups.

## Review Output

Reviews and proposals live under:

- `.agents/improvement/session-reviews/`
- `.agents/improvement/local-proposals/`
- `.agents/improvement/forward-to-meta/`

## Approval Boundary

Agents may create review and proposal documents without approval. They may not update the process or policy docs only because a self-review suggested it.

## Batch Review Mode

When multiple session captures have accumulated, a batch review provides a streamlined alternative to reviewing each capture individually.

### How It Works

A batch review processes several captures at once and produces a single consolidated output covering patterns, recurring issues, and improvement proposals. The output is shorter per-capture than a full individual review because it focuses on cross-session patterns rather than per-session details.

### Recommended Cadence

The recommended cadence is to run a batch review after every 5 session captures. This balances review effort against pattern visibility — fewer than 5 captures rarely surface meaningful trends, while more than 5 makes the batch unwieldy.

### Automatic Trigger

The session-capture skill tracks how many captures have been recorded since the last review. When the count reaches the review threshold, it recommends running a batch review. This is a recommendation, not an automatic action — you decide whether to proceed.

### Batch vs Full Per-Capture Review

A full per-capture review examines one session in detail: what went well, what went wrong, specific process deviations. A batch review trades that depth for breadth — it surfaces patterns across sessions (e.g., repeated blockers, consistently skipped steps, areas where the plan of record was inadequate). Use full reviews when a specific session had notable problems; use batch reviews for routine process health checks.

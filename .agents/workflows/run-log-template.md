# Run-Log

Append an entry after every meaningful execution step. This is not optional. If the session is interrupted, this log is the only record of progress.

## Entry Format

Use append-only entries with:

- timestamp
- actor
- planned step
- action taken
- result
- files touched
- verification run
- criteria impact
- blocker or risk

## Example Entry

<!-- Remove this example after writing the first real entry. -->

```markdown
### 2026-04-13 14:30

- **Actor**: claude
- **Planned step**: Add input validation to user registration endpoint
- **Action taken**: Added schema validation middleware to POST /api/users route
- **Result**: success
- **Files touched**: src/routes/users.js, src/middleware/validate.js
- **Verification**: npm test passed (12/12); manual curl test confirmed 400 on invalid input
- **Criteria impact**: AC-1 (input validation) — now met
- **Blocker / Risk**: none
```

## Log Entries

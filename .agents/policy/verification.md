# Verification Policy

Verification is any concrete check that increases confidence in the result, such as tests, builds, linters, focused manual inspection, or structured document validation.

## Required

- Run verification after meaningful implementation phases when the project affords it.
- Record what was run, what passed, and what remains unverified.
- Environment and repository-state claims — repository visibility, remote configuration, tool
  or gateway capability, what a command does — must be verified by running the command before
  being written into a tracked artifact.
  Record the command and its output, not the conclusion you drew from it.
  A document's stated intent ("this repo stays public") is evidence about the document, not
  about the present state, and an inference drawn from source code is evidence about the source.
  Both read exactly like a measurement once they are written down, which is why the command has
  to sit beside the claim.

## Reporting

- Put workflow-phase verification in `run-log.md`.
- Put session-level verification in a session capture when no workflow packet exists.

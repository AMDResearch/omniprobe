# Dossier Template

## Metadata

- Workflow ID:
- Workflow Type:
- Lifecycle State:
- Owner / Current Executor:
- Intended Write Scope:
- Dependencies On Other Active Workflows:
- Base Commit: (unstamped — set at promotion)

`Lifecycle State` is a cross-check, not the source of truth: the packet's **directory** decides
its state, and `ac_check_write_scope` reports a disagreement between the two rather than
resolving it silently. Keep the field current anyway — a mismatch is noise in every gate run.

`Base Commit` is stamped at the `draft` → `active` transition with `git rev-parse HEAD`, and is
what lets the scope check see writes that have already been committed. Leave the placeholder
while the packet is in `draft`. In a **sidecar install** add a second line,
`- Base Commit (code): <sha>`, carrying the target repository's HEAD — the two roots are
independent histories and one stamp cannot cover both. See `INDEX.md`.

The `write-scope` block below is canonical; leave the metadata line above empty unless this
dossier predates the block. List every path this workflow may write to, one per line, inside
the block. Directories end with a slash; blank lines and `#` comments are ignored.

```write-scope
# path/to/a/file.py
# path/to/a/directory/
```

The block is machine-readable on purpose. `ac_check_write_scope` parses it and fails naming
anything the working tree has touched outside it, so the declared scope and the checked scope
cannot drift apart. A dossier with no block falls back to parsing the prose
`- Intended Write Scope:` line and reports `WEAK` even when clean — that fallback exists only
for dossiers written before the block did. Write the block.

**Amending the block.** Widening a declared scope mid-workflow is a *scope amendment*: add the
path here, log it in `handoff.md` under `## Scope Amendments` and in `run-log.md`, and carry on.
It does not need approval first — see `.agents/policy/guardrails.md`. Annotate the added entry
with a dated `#` comment, which the parser ignores:

```write-scope
docs/usage/
README.md          # amended 2026-08-17 — AC-21 requires the doc to be reachable from an index
```

Framework-owned paths are allowlisted by the library and need not be declared: `.agents/state/`,
`.agents/pm/`, `.agents/improvement/`, `.agents/workflows/seeds/`, **this packet's own directory**
under `.agents/workflows/<state>/<id>/`, `.untracked/`, `__pycache__/`, and `.pytest_cache/`.
Note the ownership rule: a packet may write anywhere inside its own directory without declaring
it, keyed on the packet **id** so that moving from `active/` to `done/` changes nothing, but
writing into **another workflow's packet** — its dossier, its acceptance script — must be
declared like any other path. Before P1.2 it need not be, and no gate reported it. These are
paths the framework itself writes during any session — `session-close` runs `pm-update`
unconditionally — so without the allowlist every run would report them as out of scope. Note that
the templates living directly in `.agents/workflows/` are *not* allowlisted: editing
`dossier-template.md` still has to be in a declared scope.

**Declaring a framework path re-enables checking for it.** An allowlist entry goes inert for any
region this block claims, so if your deliverable *is* PM content, declare the exact paths you
mean — say `.agents/pm/units/my-unit.md` — and a stray write to a sibling under `.agents/pm/` is
reported again. Declaring is therefore stricter than staying silent, not looser: the allowlist
can never hide a path the dossier named.

In a **sidecar install** the check reports over both repositories. Paths dirty in the target repo
are checked against this block alone, with no allowlist — the allowlist names framework-owned
paths, and the target repo is code. Reported paths carry a `code:` or `framework:` prefix so you
can tell which repository a finding came from.

## Objective

## Background / Context

## Contract

## Acceptance Criteria

Number the criteria (`AC-1`, `AC-2`, …) and write each so a script can decide it. Every
criterion needs a matching check in the packet's `acceptance.sh`, and
`workflow-readiness-check` fails a packet whose criteria are prose-only.

A criterion that genuinely cannot be decided mechanically — typically a claim about how an agent
behaves after reading a document — is marked `[judgement]` **and must state why**. A bare marker
is not acceptable; the reason is what a human reviewer, or the optional validator, acts on.
Judgement criteria are reported as `JUDGE` and never gate the exit code:

- **AC-7**: `workflow-create` records a reason for every judgement criterion. Verified by
  reading the SKILL.md. **[judgement]** — reason: this is a claim about how an agent behaves
  after reading a SKILL.md. The file-level check that the instruction is present is mechanical
  and is asserted separately; whether an agent then follows it is not.

Before reaching for the marker, try rewording the criterion so it becomes checkable. Expect
roughly a fifth of a real dossier to resist that; the marker is for those, not for criteria that
were merely inconvenient to specify.

## Failure Policy

## Scope

## Non-Goals

## Constraints and Assumptions

## Dependencies

## Plan Of Record

## Verification Strategy

One row per criterion, naming the command or check that decides it. A check that only greps for
text establishes text presence, not meaning — say so here and report it as `WEAK` in
`acceptance.sh` rather than letting it print as `PASS`.

## References

## Open Questions

# Workflow Index

## Seeds vs Packets

Rough work requests that are not yet structured enough to be a workflow packet live in `.agents/workflows/seeds/` as plain markdown files. They are not packets — they have no dossier, run-log, handoff, or artifacts file.

When a seed is refined into a structured packet (via `workflow-refine` or `workflow-create`), it becomes a packet directory under the appropriate lifecycle state directory.

## Workflow Type Prefixes

- `rf_` — refactor
- `ft_` — feature
- `bf_` — bug fix
- `iv_` — investigation
- `rv_` — review
- `pf_` — performance

## Packet Lifecycle States

Workflow packets live under `.agents/workflows/<state>/<workflow-id>/`.

- `draft` — structured packet exists but is not yet approved for autonomous execution
- `active` — approved and being executed
- `suspended` — paused intentionally; can be resumed
- `blocked` — cannot proceed; waiting on an external dependency or decision
- `failed` — contract could not be met; agent stopped
- `done` — completed and accepted
- `abandoned` — intentionally dropped; will not be resumed

## Packet Files

Each packet directory contains:

- `dossier.md` — the contract and plan
- `run-log.md` — append-only execution history
- `handoff.md` — concise resume state for cross-session handoff
- `artifacts.md` — output index and verification evidence
- `acceptance.sh` — the acceptance criteria, executable

## The Acceptance Script

`acceptance.sh` is the dossier's Acceptance Criteria section in a form a machine can decide.
Start from `.agents/workflows/acceptance-template.sh`, keep one call per criterion in the
dossier's order, and end with `ac_finish`. It exits 0 if and only if nothing failed.

Exit 0 is the only evidence a workflow may stop. `workflow-complete` will not move a packet to
`done/` until it does, and `.agents/hooks/stop-acceptance.sh` — a `command`-type Stop hook,
registered per-invocation for autonomous runs — refuses to let an agent finish while it fails,
handing the script's own output back as the reason.

Four verdicts, from `.agents/hooks/acceptance-lib.sh`:

| Verdict | Meaning | Gates exit code |
|---------|---------|-----------------|
| `PASS` | the check establishes the property | — |
| `WEAK` | the check is indirect, usually text presence; it can pass on input lacking the property | no |
| `JUDGE` | not mechanically checkable; a human or the optional validator decides | no |
| `FAIL` | the property does not hold | **yes** |

`WEAK` and `JUDGE` exist so that a check which cannot prove what it claims never prints as if it
had. Do not upgrade one to `PASS` to make the output tidier.

A packet with no `acceptance.sh` is unaffected: the gate is absent, not failed. The convention is
not retrofitted onto packets that predate it.

## Moving Packets Between States

The agent moves a packet by relocating its directory from one lifecycle directory to another (e.g., `draft/ft_login/` to `active/ft_login/`). After every move:

1. Update the packet's `dossier.md` metadata to reflect the new lifecycle state.
2. Update `.agents/state/active-workflows.md` to reflect the new state.

Do not keep a second tracking table in this file. `active-workflows.md` is the one place
workflow state is recorded, and it is preserved across upgrades; this file is framework
reference content and an upgrade refreshes it, so anything written here is lost the next time
the project is upgraded. An earlier version of this list invited exactly that.

The user must approve the transition from `draft` to `active`. All other transitions may be initiated by the agent when warranted by the execution state.

### Stamping the base commit — required at `draft` → `active`

Promotion has one further required step. Record the commit the workflow starts from in the
dossier's metadata:

```
- Base Commit: $(git rev-parse HEAD)
```

Write the resolved value, not the command. In a **sidecar install** add a second line with the
*target* repository's HEAD, because the two roots are independent histories and one stamp cannot
cover both:

```
- Base Commit (code): <git rev-parse HEAD, run in the target repo>
```

**Why it is required.** `ac_check_write_scope` compares the declared scope against
`git status --porcelain`, which only ever sees the dirty tree — so committing a file removes it
from the check entirely, and the framework simultaneously tells agents to commit as they go. The
stamp is what lets the check also scan every commit the workflow has made since promotion. A
packet in `active/`, `suspended/` or `blocked/` with no stamp reports `WEAK` rather than `PASS`:
an unstamped packet has not had that hole closed and must not look like one that has. A `draft/`
packet is unstamped by definition.

There is no `workflow-promote` skill, so this step belongs to whichever agent performs the move.
`workflow-readiness-check` reports the stamp as present or absent but does not write it.

## Coordination

Use `.agents/state/active-workflows.md` to coordinate multiple workflows in parallel.

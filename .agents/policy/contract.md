# Contract Preservation Policy

- The agent may change implementation approach without approval.
- The agent may not weaken, redefine, or substitute acceptance criteria without approval.
- If the contract cannot be met, the agent stops, reports the blocker, and proposes options.
- Proposed spec changes belong in workflow `handoff.md`, not by silently rewriting the dossier.

## Scope Amendment Versus Contract Change

Stated here as well as in `guardrails.md`, because it is a rule about what the contract
protects and belongs where contract preservation is defined.

| | Weakening an acceptance criterion | Widening a declared write scope |
|---|---|---|
| What it is | a **contract change** | a **scope amendment** |
| Effect on evidence | **destroys** it — changes what "done" means | **adds** it — one line in a tracked file |
| Visible afterwards | no, the finished artifact looks the same | yes, in the diff |
| Caught if repeated | no | yes, the same gate fires again |
| Required before proceeding | user approval | declare in the `write-scope` block; log in `handoff.md` under `## Scope Amendments` and in `run-log.md` |

A scope amendment is reviewed after the fact. It is logged rather than proposed, which is why
`## Scope Amendments` is a section of its own and not part of `## Proposed Spec Changes` —
putting a completed action under a heading that means "awaiting approval" would misreport it.

The contract-controlled sections are the acceptance criteria, the failure policy, and the
non-goals. The `write-scope` block is a declaration, not a contract term: it says where this
workflow writes, and correcting it to match what the work actually required makes it more
accurate, not less binding.

## Autonomous Execution Default

When an agent is directed to execute or resume a workflow, autonomous execution is the
default mode. The agent:

- Proceeds through the plan of record without pausing for approval at each step.
- Follows all stop conditions in `guardrails.md` (blocker, scope violation, safety risk,
  contract violation, write-scope collision, uncertainty about a destructive action).
- Reports progress through run-log entries and handoff updates, not through mid-execution
  check-ins.
- Declares the execution mode to the user at the start so expectations are clear.

The user may override this default by requesting step-by-step execution or approval gates.
Absent such a request, treat "execute <workflow-id>" as full authorization to work
autonomously within the workflow's contract.

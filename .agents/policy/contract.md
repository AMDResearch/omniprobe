# Contract Preservation Policy

- The agent may change implementation approach without approval.
- The agent may not weaken, redefine, or substitute acceptance criteria without approval.
- If the contract cannot be met, the agent stops, reports the blocker, and proposes options.
- Proposed spec changes belong in workflow `handoff.md`, not by silently rewriting the dossier.

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

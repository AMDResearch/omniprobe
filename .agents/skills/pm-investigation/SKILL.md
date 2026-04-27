---
name: pm-investigation
description: |
  Create or manage an investigation workflow packet. Use when the user needs to
  explore an unknown, test hypotheses, or answer a question whose output is
  knowledge rather than code. Structures the work around hypotheses, evidence
  collection, and decision-ready conclusions.
---

# pm-investigation

## Purpose

Create or manage an investigation workflow packet. Investigations explore unknowns, test hypotheses, and produce decision-ready conclusions. The output is knowledge, not code. This skill emphasizes structured hypotheses, evidence collection, and clear recommendations.

## Required Reads

1. `.agents/workflows/INDEX.md` -- understand lifecycle states and packet structure.
2. `.agents/workflows/dossier-template.md` -- the dossier format to follow.
3. `.agents/pm/pm-current-state.md` -- check for related active work and known risks.
4. Relevant PM units for the area under investigation (via pm-load).

## Procedure

### Creating a new investigation packet

1. **Choose the workflow ID.** Use the prefix `iv_` followed by a short descriptive slug. Example: `iv_memory_leak_api_server`.
2. **Create the packet directory.** Path: `.agents/workflows/draft/iv_<slug>/`.
3. **Write `dossier.md`.** Copy the structure from `dossier-template.md` and fill in:
   - Metadata: set Workflow Type to "investigation", Lifecycle State to "draft".
   - Objective: state the question being answered. Frame it as a question, not a task. Example: "Why does the API server's memory grow by 50MB/hour under steady load?"
   - Background/Context: summarize what is already known, including symptoms, prior attempts, and relevant data points.
   - Contract: define what a sufficient answer looks like. Example: "Root cause identified with evidence, and at least two remediation options evaluated."
   - Acceptance Criteria: list the specific deliverables. Typical set:
     - Hypotheses listed with supporting and contradicting evidence.
     - Root cause identified or top candidates ranked by likelihood.
     - Recommended action with rationale.
     - Key evidence preserved in artifacts.
   - Failure Policy: define when to stop investigating. Default: "If no progress after 3 evidence-gathering cycles, document findings so far and recommend external escalation."
   - Scope: list the files, logs, systems, or data sources to examine.
   - Plan of Record: structure the investigation as: (a) form hypotheses, (b) design evidence-gathering steps, (c) collect evidence, (d) evaluate and narrow, (e) conclude.
   - Verification Strategy: describe how conclusions will be validated (e.g., reproduce the issue, confirm fix in staging).
   - Open Questions: seed with the initial unknowns.
4. **Write `run-log.md`.** Initialize from `run-log-template.md`. Investigation run-logs should record each hypothesis tested, evidence found, and whether the hypothesis was supported or refuted.
5. **Write `handoff.md`.** Initialize from `handoff-template.md`. Set "Next Exact Step" to the first evidence-gathering action.
6. **Write `artifacts.md`.** Initialize from `artifacts-template.md`. Investigations should index: data captures, log excerpts, benchmark results, and any reproduction scripts.
7. **Update `.agents/workflows/INDEX.md`** if a tracking table is maintained.

### Managing an existing investigation packet

1. **After each evidence-gathering step**, append a run-log entry: hypothesis under test, evidence collected, verdict (supported / refuted / inconclusive), and remaining hypotheses.
2. **Update `handoff.md`** with current hypothesis ranking and next evidence step.
3. **When concluding**, write a summary in `artifacts.md` with: final answer, confidence level, key evidence references, and recommended next actions.
4. **Move the packet to done** only when the acceptance criteria are met. If the question cannot be fully answered, move to done with partial findings documented, or to failed if no useful progress was made.

## Output

- `.agents/workflows/draft/iv_<slug>/dossier.md`
- `.agents/workflows/draft/iv_<slug>/run-log.md`
- `.agents/workflows/draft/iv_<slug>/handoff.md`
- `.agents/workflows/draft/iv_<slug>/artifacts.md`

## Completion Criteria

- All four packet files exist and follow their respective templates.
- The objective is framed as a question.
- At least two hypotheses are listed in the dossier or run-log.
- The contract defines what a sufficient answer looks like.
- The failure policy includes a stop condition to prevent unbounded investigation.

## Error Handling

- If the investigation scope is too broad (more than 5 hypotheses spanning unrelated systems), recommend splitting into multiple investigation packets.
- If evidence is inaccessible (e.g., production logs unavailable), document the gap in the dossier under Constraints and adjust the plan to work with available data.
- If the investigation reaches the failure policy threshold, write up partial findings, move the packet to failed, and persist any useful negative knowledge to PM via pm-update.

---
name: pm-performance
description: |
  Create or manage a performance workflow packet. Use when the user wants to
  measure, benchmark, or optimize runtime performance with measurable baselines
  and targets. Drives performance work to completion with evidence at every step.
---

# pm-performance

## Purpose

Produce a structured workflow packet that drives a performance investigation or optimization to completion with measurable evidence at every step.

## Required Reads

- `.agents/pm/pm-current-state.md` -- understand active work and recent changes
- `.agents/workflows/INDEX.md` -- check for existing performance packets
- `.agents/state/active-workflows.md` -- check for write-scope overlap
- `.agents/workflows/dossier-template.md` -- packet structure reference
- `.agents/docs/examples/performance-example.md` -- example packet content

## Procedure

1. Ask the user what performance concern they want to address. Collect: the target area, the metric (latency, throughput, memory, etc.), and the acceptable threshold.
2. Generate a workflow ID using the prefix `pf_` followed by a short slug (e.g., `pf_api_latency`).
3. Create the packet directory at `.agents/workflows/draft/pf_<slug>/`.
4. Write `dossier.md` with these performance-specific expectations:
   - Objective states the metric and target threshold.
   - Background describes current known performance and why it matters.
   - Acceptance Criteria include a measurable baseline measurement, a target measurement, and the methodology for reproducing both.
   - Verification Strategy specifies the exact commands or test harness to run.
   - Plan of Record starts with "Establish baseline" as step 1.
5. Write `run-log.md` from the run-log template with an initial entry noting packet creation.
6. Write `handoff.md` with status "draft", next step "Establish baseline measurement", and required reads listing the dossier.
7. Write `artifacts.md` with an empty table ready for baseline results, benchmark outputs, and comparison reports.
8. Update `.agents/state/active-workflows.md` to list the new packet.
9. Present the draft dossier to the user for review before any transition to `active`.

## Output

- Packet directory: `.agents/workflows/draft/pf_<slug>/`
- Files: `dossier.md`, `run-log.md`, `handoff.md`, `artifacts.md`
- Updated `.agents/state/active-workflows.md`

## Completion Criteria

- All four packet files exist and are internally consistent.
- The dossier contains a specific metric, a baseline methodology, and a measurable target.
- The acceptance criteria can be evaluated by running the verification strategy.
- The packet is listed in `active-workflows.md`.

## Error Handling

- If no measurable metric can be defined, stop and tell the user the request needs a concrete measurement target before a packet can be created.
- If write scope overlaps with another active workflow, flag the conflict in the dossier metadata and warn the user.
- If baseline tooling does not exist in the repo, note it as a blocker in `handoff.md` and set the first plan step to "Set up measurement harness."

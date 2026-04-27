---
name: pm-reflect
description: |
  Assess whether PM granularity and structure match current work patterns. Use
  after several workflows have completed, or when PM feels bloated or
  fragmented. Checks coverage gaps, split/merge candidates, load frequency,
  and transient noise. Produces a reflection report with recommendations.
---

# pm-reflect

## Purpose

Over time, PM units drift from the project's actual shape: units stay monolithic while work splits into subdomains, or units fragment into noise no one loads. This skill identifies structural mismatches so the user can decide whether to reorganize.

## Preconditions

- PM has been initialized and has at least two units.
- At least one workflow has reached `done` state, so there is a work-pattern baseline to reflect against.

## Required Reads

1. `.agents/pm/pm-index.md` -- unit registry with purpose and load-trigger metadata.
2. `.agents/pm/pm-current-state.md` -- active work areas and risks.
3. All unit files in `.agents/pm/units/`.
4. `.agents/state/active-workflows.md` -- current parallel work.
5. Up to 5 recent workflow `dossier.md` files from `.agents/workflows/done/` (select the most recent by directory name).
6. `.agents/improvement/failure-modes.md` -- for patterns like "loaded far more PM than the task required."

## Procedure

1. **Coverage gap analysis.** List the major subsystems or work areas visible in active and recent-done workflows. For each, check whether a PM unit exists that covers it. Record uncovered areas.
2. **Granularity assessment.** For each unit, count the number of distinct topics in its Current Truth section. If a single unit covers more than 3 unrelated topics, flag it as a split candidate. If two or more units cover the same narrow topic, flag them as merge candidates.
3. **Load-frequency estimate.** For each unit, count how many of the recent workflow dossiers reference it (by name or by the subsystem it covers). Flag units referenced by zero workflows as potentially obsolete. Flag units referenced by every workflow as potentially too broad.
4. **Transient noise check.** Scan each unit's Current Truth for statements that describe temporary states (e.g., "currently blocked on...", "waiting for PR...", version-pinned workarounds). Flag these as transient noise that belongs in a workflow packet, not PM.
5. **Negative knowledge audit.** Check whether any unit's Negative Knowledge section is empty. Cross-reference with `failure-modes.md` to see if known failure patterns should be captured as negative knowledge in specific units.
6. **Compile recommendations.** For each finding, state the specific unit name, the issue, and a concrete suggested action (split, merge, archive, extract, add negative knowledge).

## Output

Write a reflection report to `.agents/pm/reflection-report.md`:

```markdown
# PM Reflection Report

**Date:** YYYY-MM-DD

## Coverage Gaps
- <work area> -- no PM unit covers this

## Split Candidates
- <unit name> -- covers N unrelated topics: <list>

## Merge Candidates
- <unit A> + <unit B> -- both cover <topic>

## Potentially Obsolete Units
- <unit name> -- referenced by 0 recent workflows

## Transient Noise
- <unit name> :: "<quoted statement>" -- move to workflow packet

## Missing Negative Knowledge
- <unit name> -- failure mode "<pattern>" from failure-modes.md not captured

## Recommendations
1. <concrete action>
```

Omit any section where no issues were found.

## Completion Criteria

- Every existing PM unit has been assessed for granularity and load frequency.
- The report contains only concrete, actionable findings with unit names.
- Recommendations are suggestions, not changes. No PM files were modified.
- To execute structural recommendations (splits, merges, archives, creates), run `/pm-restructure`.

## Error Handling

- If fewer than 2 units exist, stop and report: "PM too small to reflect on. Build more units first."
- If no workflows have reached `done`, skip load-frequency analysis and note it was skipped.
- If `failure-modes.md` is empty or missing, skip the negative knowledge cross-reference and note it.
- Do NOT modify any PM files. This skill produces a report only.

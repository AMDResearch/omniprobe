# PM Maintenance

This document defines how and when an agent updates Project Memory. PM stores durable, reusable project knowledge — not session-specific details.

## When To Update PM

Update PM when you learn something **durable** that future sessions should reuse. Durable means it will still be true and useful across multiple future sessions.

### Trigger Conditions

- You discovered a stable architectural boundary or dependency.
- A project-level decision was made that constrains future work.
- An approach was tried and failed — the negative knowledge has lasting value.
- A term or acronym appeared that future sessions must interpret consistently.
- The project's active work areas, risks, or focus materially changed.

### What Stays Out of PM

- Session-specific execution details (those belong in `run-log.md`).
- Temporary blockers that will resolve within the current session.
- Raw transcripts or conversation history.
- Detailed step-by-step instructions (those belong in SKILL.md files or workflow dossiers).

## Update Procedure

1. **Filter for durability.** Before writing anything, ask: "Will a fresh agent session 2 weeks from now benefit from knowing this?" If no, skip it.
2. **Update affected PM units** in `.agents/pm/units/`. Modify the relevant sections (Current Truth, Negative Knowledge, Open Questions, etc.). Update the `Last Verified` field with today's date and your identifier.
3. **Create new units** when you discover a durable knowledge boundary that does not fit in an existing unit. Follow the unit schema: Purpose, Current Truth, Boundaries and Dependencies, Anchors/References, Negative Knowledge, Open Questions, Related Workflows, Last Verified.
4. **Update `pm-index.md`** when you create, rename, or change the status of a unit.
5. **Update `pm-current-state.md`** when the project's active work areas, risks, or focus changed materially.
6. **Record decisions** in `pm-decisions.md` when a project-level decision was made with durable impact. Include date, decision, rationale, and source.
7. **Add terms** to `pm-glossary.md` when project-specific vocabulary appeared that could be misinterpreted.

## Unit Lifecycle

| Action | When |
|---|---|
| Create unit | A new durable knowledge boundary is identified |
| Update unit | Verified facts changed, negative knowledge emerged, or open questions resolved |
| Split unit | A unit covers too many unrelated concerns and is hard to load selectively |
| Merge units | Two units overlap significantly and are always loaded together |
| Move to `done/` | The knowledge area is no longer active (e.g., a deprecated module) |

## Maintaining Code-Navigation Units

Code-navigation units map source-code subsystems and require more frequent updates than infrastructure units. This higher update frequency is by design — code-navigation units trade durability for actionability, keeping agents oriented in actively changing code.

### When To Refresh

Refresh code-navigation units when:

- Source files are added, moved, or renamed within a covered subsystem.
- A new subsystem is introduced that warrants its own unit.
- A substantial restructuring changes the data flow, key interfaces, or module boundaries of a covered subsystem.
- The unit's anchor paths no longer resolve to existing files.

### Keeping The Architecture Overview Current

When subsystems are added or removed, update the architecture overview unit to reflect the change. The overview should list all active subsystems and their relationships. If a subsystem is removed, move its reference out of the overview; if one is added, add a brief entry describing its role and how it connects to existing subsystems.

### pm-validate Self-Healing

When `pm-validate` discovers PM units that exist on disk but are not listed in the PM index, it auto-adds them. This self-healing behavior prevents units from becoming invisible after creation. It does not, however, verify content accuracy — that remains the responsibility of the agent performing the update.

## When To Run `pm-validate`

Run `pm-validate` when:

- A major refactor changed the repo structure.
- Multiple sessions have passed without PM review.
- You notice that a PM unit's anchors (file paths, module names) no longer match the repo.
- You suspect units have become stale (the Last Verified date is more than 30 days old).

## When To Run `pm-reflect`

Run `pm-reflect` when:

- Several workflows have completed since the last reflection.
- You find yourself repeatedly loading units that are not useful, or missing units that would have helped.
- The project's focus has shifted significantly from what PM describes.

## Stale-State Symptoms

Watch for these signs that PM has drifted:

- PM unit references files or modules that no longer exist.
- `pm-current-state.md` describes work areas that are no longer active.
- The recommended reading order in `pm-current-state.md` does not match the actual project focus.
- A unit's "Current Truth" section contradicts what you observe in the code.

## Reconciliation When State Disagrees

If PM and other state files disagree:

1. Trust the code and the actual repository structure over PM.
2. Trust `active-workflows.md` over `pm-current-state.md` for which workflows are active.
3. Update PM to match reality — do not update reality to match PM.
4. Log the correction in the PM unit's Negative Knowledge section if the stale information could mislead future sessions.

## Stop Conditions

- Do not update PM with information you are uncertain about. Mark it as an Open Question instead.
- Do not delete PM units without checking whether other units or workflows reference them.
- Do not update PM if the only source is your own inference. PM records observed, verified project truths.

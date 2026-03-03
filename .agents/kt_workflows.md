# Knowledge Tree Workflow Commands

Commands for maintaining the knowledge tree in `.agents/kt/`.

---

## Command: `kt-help`

**Purpose**: Show available KT commands.

**Output**:
```
Knowledge Tree Commands:

  kt-help       Show this help
  kt-init       Create KT structure for new project
  kt-load       Load context at session start
  kt-update     Persist learnings at session end
  kt-validate   Check for stale dossiers
  kt-reflect    Assess KT granularity for current task

  kt-refactor start <goal>   Begin new refactor
  kt-refactor suspend        Checkpoint current refactor
  kt-refactor resume [slug]  Continue existing refactor
  kt-refactor finish         Finalize completed refactor
  kt-refactor list           Show all refactors

See .agents/kt_usage.md for quick reference.
```

---

## Sub-project Conventions

Projects may contain git submodules or nested sub-projects. Each sub-project can have its own `.agents/kt/` that describes it in isolation. The top-level knowledge tree:
- Describes how sub-projects integrate
- References sub-project KTs rather than duplicating their content
- Adds integration-specific invariants and data flows

When working on a sub-project, load both the top-level architecture and the sub-project's KT.

---

## Command: `kt-init`

**Purpose**: Create initial knowledge tree for a project that doesn't have one.

**When to use**: First session on a project, or when `.agents/kt/` is empty.

**Steps**:

1. **Survey the codebase**
   - Identify major subsystems (directories, libraries, components)
   - Identify sub-projects (git submodules, external dependencies with source)
   - Note primary entry points and data flows
   - Limit exploration: max ~20 files sampled, focus on structure not details
   - **Source priority**: Treat source code as ground truth. Documentation (READMEs, docs/) may be outdated; use it for hints but verify against code. Build files (CMakeLists.txt, etc.) are reliable for understanding project structure.

2. **Create `architecture.md`**
   - High-level system map (ASCII diagram if helpful)
   - List of subsystems with one-liner descriptions
   - List of sub-projects with locations and purpose
   - Primary data flows
   - Key invariants (system-wide constraints)
   - Links to subsystem dossiers

3. **Create one dossier per major subsystem** (`<subsystem>.md`)
   - Use the dossier template (see below)
   - Keep to ~100-200 lines; split if larger
   - One dossier per component that would merit its own README
   - For sub-projects: create a brief integration dossier at top-level, defer internals to sub-project's own KT

4. **Initialize sub-project KTs** (if sub-projects exist)
   - Run `kt-init` in each sub-project's directory
   - Or defer until that sub-project is actively worked on

5. **Create `glossary.md`** (if domain has non-obvious terminology)
   - Term → definition mapping
   - Keep concise

**Granularity heuristics**:
- One dossier per subsystem, not per file
- If a component has 3+ files working together, it's a subsystem
- If you'd explain it separately to a new team member, it deserves a dossier
- Sub-projects get their own KT; top-level describes integration only

---

## Command: `kt-load`

**Purpose**: Rehydrate context at session start.

**When to use**: Beginning of any session where the knowledge tree exists.

**Steps**:

1. **Always load**: `architecture.md`

2. **Load based on session scope**:
   - If user specifies a subsystem: load that dossier + any listed in its "Also Load" section
   - If user specifies a task: infer relevant subsystems, load those dossiers
   - If unclear: ask user which area they're working on

3. **Load sub-project KTs if relevant**:
   - If working on a sub-project, load its `.agents/kt/architecture.md`
   - Load sub-project dossiers based on task scope
   - The top-level integration dossier tells you which sub-project KT to load

4. **Note the session intent** (for `kt-update` later):
   - What subsystem(s) are in scope
   - What kind of work (feature, bugfix, refactor, exploration)

---

## Command: `kt-update`

**Purpose**: Persist learnings from the current session into the knowledge tree.

**When to use**: End of session, or after significant changes.

**Steps**:

1. **Review what changed this session**
   - Files modified/created
   - New understanding gained
   - Decisions made
   - Approaches tried and rejected

2. **Update relevant dossiers**:
   - Add new interfaces/symbols if significant
   - Update invariants if they changed
   - Add to "Rejected Approaches" if structural dead-ends were discovered
   - Update "Known Limitations" or "Open Questions" as needed
   - Update "Last Verified" commit/date

3. **Update `architecture.md`** if:
   - New subsystems were added
   - Data flows changed
   - System-wide invariants changed

4. **Update sub-project KTs** if work was done there:
   - Update the sub-project's own `.agents/kt/` dossiers
   - Update top-level integration dossier if integration behavior changed
   - Keep sub-project KT focused on internals; top-level focuses on integration

5. **Granularity check**:
   - If a dossier exceeds ~300 lines, consider splitting
   - Remove stale information rather than accumulating
   - Don't document micro-decisions or debugging steps

6. **Negative knowledge**:
   - Record structural impossibilities, not anecdotal failures
   - Good: "X cannot work because of constraint Y"
   - Bad: "We tried X and it didn't work"

---

## Dossier Template

```markdown
# <Subsystem Name>

## Responsibility
One-paragraph description of what this subsystem does.

## Core Concepts
- **Term1**: Definition
- **Term2**: Definition

## Key Invariants
- Constraint 1
- Constraint 2

## Data Flow
How data enters, transforms, and exits this subsystem.

## Interfaces
Key entry points with file:line anchors.
- `function_name()` — purpose — `path/to/file.cpp:42`
- `ClassName` — purpose — `path/to/file.h:15`

## Dependencies
Other subsystems this one interacts with.

## Also Load
Dossiers to load alongside this one for full context.

## Performance Constraints
(If relevant)

## Known Limitations
Current constraints or technical debt.

## Rejected Approaches
Structural approaches that won't work, with reasons.
- **Approach**: Why it's not viable

## Open Questions
Unresolved design questions.

## Last Verified
Commit: <hash or "N/A">
Date: <YYYY-MM-DD>
```

---

## Command: `kt-refactor`

**Purpose**: Manage refactor dossiers — persistent work-item trackers for multi-session refactoring tasks.

**Why refactor dossiers?**
Refactoring is constraint preservation under partial observability. Unlike greenfield features, refactors must:
- Preserve API/ABI compatibility
- Maintain semantic invariants (ordering, lifetimes, ownership)
- Handle hidden coupling (macros, templates, build flags)
- Track progress across sessions

A refactor dossier is separate from subsystem dossiers — it tracks a *work item*, not stable structure.

**Subcommands**:
- `kt-refactor start <goal>` — begin new refactor
- `kt-refactor suspend` — checkpoint and pause current refactor
- `kt-refactor resume <slug>` — continue existing refactor
- `kt-refactor finish` — finalize completed refactor
- `kt-refactor list` — show all refactors with status

**Multiple concurrent refactors**: You can have multiple refactors in progress simultaneously. Use `suspend` to pause one and `resume <slug>` to switch to another. Use `list` to see all active refactors.

---

### `kt-refactor start <goal>`

**Purpose**: Begin a new refactor with interactive discovery.

**Input**: A high-level change request, e.g.:
- "kt-refactor start extract handler interface into standalone header"
- "kt-refactor start comms_mgr to use RAII for buffer management"

The user provides the *goal*; we discover the *scope* and *constraints* together.

**Steps**:

1. **Create refactor dossier**:
   - Generate slug from goal description
   - Location: `.agents/kt/refactors/rf_<slug>.md` (active refactors in `refactors/`, completed in `refactors/done/`)
   - Create from template

2. **Survey the code**:
   - Load relevant subsystem dossier(s) from KT
   - Read key source files to identify affected symbols
   - Map out call graph impact
   - Identify risks and hidden coupling

3. **Discuss with user** to establish contract:
   - Confirm goal interpretation
   - Ask about invariants: "Does ABI need to be preserved?" "Any performance constraints?"
   - Agree on verification gates: "What tests should pass?"
   - Clarify any ambiguities before proceeding

4. **Draft the dossier** (interactively):
   - **Goal**: What changes (be specific)
   - **Non-goals/Invariants**: What must NOT change (ABI, perf, threading, determinism)
   - **Verification gates**: What proves correctness (build targets, tests, runtime checks)
   - **Affected symbols**: Types, functions that will change
   - **Expected files**: Where changes will occur (hypotheses, update as confirmed)
   - **Risks**: ABI breaks, hidden dependencies, etc.
   - **Micro-step plan**: Ordered list of small, verifiable steps

5. **Get user approval**:
   - Present the dossier for review
   - User confirms contract, scope, and plan
   - Adjust if needed before proceeding

6. **Begin execution** (if approved):
   - Set status to "In Progress"
   - Start with first micro-step

---

### `kt-refactor suspend`

**Purpose**: Checkpoint current refactor for later resumption.

**When to use**: End of session when refactor is not complete.

**Steps**:

1. **Update dossier**:
   - Mark completed steps
   - Record gates passed/failed
   - Note current state and any blockers
   - Add rejected approaches discovered this session
   - Identify next step clearly

2. **Add progress log entry**:
   - Session date
   - What was accomplished
   - What was discovered
   - Next step

3. **Update metadata**:
   - Status remains "In Progress"
   - Update "Last Verified" date

---

### `kt-refactor resume <slug>`

**Purpose**: Continue an existing refactor from a previous session.

**Input**: Slug of existing refactor, or omit if only one active refactor.

**Note**: Only considers refactors with status "In Progress" (not "Done" or "Blocked"). Completed refactors are in `refactors/done/` and cannot be resumed.

**Steps**:

1. **Load refactor dossier**:
   - Search for `.agents/kt/refactors/rf_<slug>.md` with status "In Progress"
   - Load relevant subsystem dossiers referenced in scope

2. **Review state**:
   - Summarize: objective, current step, recent progress
   - Confirm understanding with user

3. **Continue execution**:
   - Proceed from current step
   - Execute with compile gates as normal

---

### `kt-refactor finish`

**Purpose**: Finalize a completed refactor.

**When to use**: All micro-steps done, refactor complete.

**Steps**:

1. **Verify completion**:
   - Confirm all micro-steps are checked off
   - Run final verification gates (full build, all tests)

2. **Update dossier**:
   - Set status to "Done"
   - Add final progress log entry
   - Update "Last Verified"

3. **Update subsystem dossiers** (if structure changed):
   - Update affected interfaces/symbols
   - Add any new invariants discovered
   - Remove outdated information

4. **Archive to done/ subdirectory**:
   - Move dossier from `.agents/kt/refactors/` to `.agents/kt/refactors/done/`
   - Completed refactors serve as historical record and learning resource
   - Keeps active refactors list clean

---

### `kt-refactor list`

**Purpose**: Show all refactors with their status.

**Output**:
```
Active refactors (.agents/kt/refactors/):

  rf_extract-handler-interface
    Status: In Progress (step 3/5)
    Last active: 2026-03-01
    Next step: Remove duplicate definition from dh_comms.h

  rf_raii-buffer-management
    Status: Blocked
    Last active: 2026-02-28
    Blocker: Waiting for dh_comms API review

Completed refactors (.agents/kt/refactors/done/):

  rf_rename-dispatch-count
    Status: Done
    Completed: 2026-02-15

  rf_remove-passthrough-wrappers
    Status: Done
    Completed: 2026-03-03
```

**Implementation**:
- Lists files in `.agents/kt/refactors/` (active: In Progress or Blocked)
- Lists files in `.agents/kt/refactors/done/` (completed: Done)
- Parses status from each dossier

**Use cases**:
- See what refactors are in flight before starting a new one
- Find the slug to resume an existing refactor
- Check for blocked refactors that may be unblocked
- Browse completed refactors for reference

---

### Multiple Concurrent Refactors

You can have multiple refactors in progress simultaneously.

**Workflow for switching**:
1. `kt-refactor suspend` — checkpoint current refactor
2. `kt-refactor resume <other-slug>` — switch to different refactor

**Guidance**:
- **Avoid overlapping scope**: Don't run concurrent refactors that touch the same files
- **Use "Blocked" status**: When a refactor is waiting on external factors
- **Prefer sequential for related changes**: If refactor B depends on refactor A, finish A first

**Blocked status**:
Set status to "Blocked" in dossier when:
- Waiting for code review
- Waiting for external dependency
- Need decision from stakeholder
- Discovered prerequisite work needed

Include blocker description in dossier:
```markdown
## Status
- [x] Blocked

### Blocker
Waiting for dh_comms API changes to be merged (PR #42).
Can resume after merge.
```

---

### Execution: Micro-step Discipline

During any active refactor (after `start` or `resume`):

1. **Execute current micro-step**:
   - Make minimal change for this step only
   - Typical order: public API (headers) → implementation → call sites

2. **Run compile/test gate**:
   - Compile after each step
   - Test after related steps complete

3. **Handle result**:
   - If gate passes: mark step done in dossier, proceed to next
   - If gate fails: diagnose and fix before proceeding — don't accumulate breakage

4. **Update dossier** as you go:
   - Check off completed steps
   - Note any discoveries or complications
   - Update expected files from hypothesis to confirmed

**Principles**:
- Prefer small diffs over large rewrites
- One logical change per step
- Never proceed past a failing gate
- If stuck, consider adding to "Rejected Approaches" and trying alternative

---

## Refactor Dossier Template

Location: `.agents/kt/refactors/rf_<slug>.md`

```markdown
# Refactor: <Short Title>

## Status
- [ ] TODO
- [ ] In Progress
- [ ] Blocked
- [ ] Done

### Blocker (if blocked)
Describe what is blocking progress and when it can be unblocked.

## Objective
What this refactor accomplishes. Be specific.

## Refactor Contract

### Goal
Precise description of the change.

### Non-Goals / Invariants
What must NOT change:
- ABI compatibility: [yes/no/n/a]
- API compatibility: [yes/no/n/a]
- Performance constraints: [describe]
- Threading model: [describe]
- Other invariants: [list]

### Verification Gates
How to prove correctness:
- Build: `make` or `ninja`
- Tests: `ctest` or specific test commands
- Runtime: [any runtime sanity checks]

## Scope

### Affected Symbols
- `ClassName::methodName()` — what changes
- `free_function()` — what changes

### Expected Files
- `path/to/file.cpp` — [confirmed/hypothesis]
- `path/to/header.h` — [confirmed/hypothesis]

### Call Graph Impact
Which callers are affected and how.

### Risks
- Risk 1: [description and mitigation]
- Risk 2: [description and mitigation]

## Plan of Record

### Micro-steps
1. [ ] Step 1: [description] — Gate: [compile/test]
2. [ ] Step 2: [description] — Gate: [compile/test]
3. [ ] Step 3: [description] — Gate: [compile/test]

### Current Step
Step N: [description]

## Progress Log
<!-- Append updates, don't delete -->

### Session YYYY-MM-DD
- Completed: [steps]
- Gates: [passed/failed]
- Discovered: [new constraints or issues]
- Next: [next step]

## Rejected Approaches
Structural approaches that won't work, with reasons.
- **Approach**: Why it's not viable

## Open Questions
Unresolved issues blocking progress.

## Last Verified
Commit: <hash or "N/A">
Date: <YYYY-MM-DD>
```

---

## Command: `kt-validate`

**Purpose**: Check if knowledge tree is stale relative to code, and optionally fix issues.

**When to use**:
- Start of session if unsure whether KT is current
- After realizing a previous session didn't run `kt-update`
- Periodically for maintenance

**Steps**:

1. **Check each dossier for staleness**:
   - Compare "Last Verified" date with modification times of files covered by dossier
   - Flag dossiers where source files changed after last verification

2. **Verify file:line anchors**:
   - For each `path/to/file.cpp:42` reference in Interfaces sections
   - Check that file exists and line number is within range
   - Flag broken anchors

3. **Verify key symbols**:
   - Check that functions/classes mentioned in Interfaces still exist in code
   - Use grep/glob to confirm symbol presence
   - Flag missing symbols

4. **Report findings**:
   - List stale dossiers with reasons
   - List broken anchors
   - List missing symbols
   - Example output:
     ```
     Stale dossiers:
       - interceptor.md: src/interceptor.cc modified 2026-02-20, Last Verified 2026-02-01
       - memory_analysis.md: 3 broken file:line anchors

     Broken anchors:
       - memory_analysis.md: `src/memory_analysis_handler.cc:142` — file has 138 lines

     Missing symbols:
       - comms_mgr.md: `growBufferPool()` not found in src/comms_mgr.cc
     ```

5. **Offer to fix**:
   - Prompt: "Found N issues. Fix them? [y/n]"
   - If yes, for each stale dossier:
     - Re-read relevant source files
     - Update Interfaces section (fix file:line anchors)
     - Flag structural changes that need human review (added to "Open Questions")
     - Update "Last Verified" date
   - If no, exit with report only

**Scope options**:
- `kt-validate` — validate all dossiers
- `kt-validate <dossier>` — validate specific dossier
- `kt-validate --fix` — skip prompt, auto-fix

**Limitations**:
- Cannot detect semantic drift (e.g., invariant that's no longer true but code still exists)
- Structural changes flagged for review, not auto-resolved

---

## Command: `kt-reflect`

**Purpose**: Self-assess whether KT granularity was appropriate for the current session's work.

**When to use**:
- Mid-session if feeling friction (too much code reading, or loaded dossiers weren't helpful)
- End of session before `kt-update`, to inform what changes to make
- When user prompts "reflect on the KT" or similar

**Reflection questions** (internal assessment):

1. **Coverage gaps** — Did I read source files that weren't covered by any dossier?
   - If yes → consider adding a dossier or expanding existing one
   - Example: "Read `src/config_receiver.cc` extensively but no dossier covers it"

2. **Unused loads** — Did I load dossiers that I never actually referenced?
   - If yes → maybe those dossiers are at wrong granularity or "Also Load" is too aggressive
   - Example: "Loaded `plugins.md` but task didn't touch plugin system"

3. **Insufficient depth** — Did a dossier exist but lack detail I needed?
   - If yes → consider expanding that dossier's Interfaces or adding subsections
   - Example: "Had to read `memory_analysis_handler.cc` line-by-line despite having `memory_analysis.md`"

4. **Excessive detail** — Did a dossier contain information that was noise for this task?
   - If yes → consider splitting task-specific details into separate dossier
   - Note: This is context-dependent; detail useful for one task may be noise for another

5. **Missing connections** — Did I discover dependencies between subsystems not documented in "Also Load" or architecture?
   - If yes → update cross-references

**Output format**:

```
KT Granularity Reflection for this session:

Task type: [bugfix | feature | refactor | exploration]
Subsystems touched: [list]

Observations:
  - Coverage gap: src/config_receiver.cc not covered by any dossier
  - Insufficient depth: memory_analysis.md lacks detail on conflict_set internals
  - Good fit: interceptor.md provided exactly what was needed

Suggestions:
  - Consider adding dossier: config_receiver.md (or fold into existing)
  - Consider expanding: memory_analysis.md → add conflict_set section
  - No changes needed: interceptor.md, comms_mgr.md
```

**Granularity principles** (task-relative):

| Task Type | Ideal Granularity |
|-----------|-------------------|
| High-level feature | Coarse: architecture + integration dossiers |
| Subsystem refactor | Medium: subsystem dossier + key interfaces |
| Specific bugfix | Fine: detailed interfaces, maybe per-class |
| Exploration | Coarse initially, refine as focus narrows |

**Action**: Reflection informs `kt-update`. Don't restructure KT mid-session; note suggestions and apply during update.

---

## Notes

- **Maintenance discipline**: Update at session end, not during coding
- **Staleness**: If source files changed significantly since "Last Verified", treat dossier as potentially stale
- **Scope**: Knowledge tree is for structural understanding, not code documentation
- **Validation**: Run `kt-validate` if you suspect staleness or skipped updates
- **Granularity**: Run `kt-reflect` to assess if KT matched the task; adjust during `kt-update`

# Knowledge Tree Workflow Commands

Commands for maintaining the knowledge tree in `.agents/kt/`.

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

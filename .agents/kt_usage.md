# Knowledge Tree Usage Guide

Quick reference for using the knowledge tree in agentic coding sessions.

## Commands Summary

| Command | When | Purpose |
|---------|------|---------|
| `kt-init` | First session | Create KT structure for new project |
| `kt-load` | Session start | Rehydrate context from KT |
| `kt-update` | Session end | Persist learnings to KT |
| `kt-validate` | Maintenance | Check for stale dossiers, fix issues |
| `kt-reflect` | Mid/end session | Assess if KT granularity fits the task |
| `kt-refactor start` | Begin refactor | Create refactor dossier interactively |
| `kt-refactor suspend` | Pause refactor | Checkpoint progress for later |
| `kt-refactor resume` | Continue refactor | Load existing dossier, continue |
| `kt-refactor finish` | Complete refactor | Finalize and archive dossier |
| `kt-refactor list` | See all refactors | Show status of all refactors |

---

## First-Time Setup

### New Project (no KT exists)

```
kt-init
```

Creates:
- `.agents/kt/architecture.md` — system overview
- `.agents/kt/<subsystem>.md` — per-subsystem dossiers
- `.agents/kt/glossary.md` — domain terms (if needed)

### Sub-projects

Sub-projects get their own KT in `<subproject>/.agents/kt/`. Top-level KT has integration dossiers that reference them.

---

## Session Workflow

### Starting a Session

```
kt-load
```

**Examples**:
- "kt-load" — loads architecture, asks what you're working on
- "kt-load, working on memory analysis" — loads architecture + memory_analysis.md
- "kt-load for dh_comms bugfix" — loads top-level + dh_comms sub-project KT

### During the Session

Just code. The KT provides context; no commands needed.

If you feel friction (reading too much code, or KT not helping):
```
kt-reflect
```

### Ending a Session

```
kt-update
```

**Examples**:
- "kt-update" — reviews changes, updates relevant dossiers
- "kt-update, we added retry logic to comms_mgr" — focused update

---

## Maintenance Commands

### Validate KT Against Code

```
kt-validate
```

**When**: Start of session if unsure KT is current, or after skipping updates.

**Examples**:
- "kt-validate" — checks all dossiers, reports issues, offers to fix
- "kt-validate interceptor.md" — check specific dossier
- "kt-validate --fix" — auto-fix without prompting

**Sample output**:
```
Stale dossiers:
  - interceptor.md: src/interceptor.cc modified after Last Verified

Broken anchors:
  - memory_analysis.md: `src/handler.cc:142` — line out of range

Found 2 issues. Fix them? [y/n]
```

### Reflect on Granularity

```
kt-reflect
```

**When**: KT feels too coarse or too detailed for current task.

**Sample output**:
```
KT Granularity Reflection:

Task type: bugfix
Subsystems touched: memory_analysis, dh_comms

Observations:
  - Coverage gap: src/config_receiver.cc not covered
  - Insufficient depth: memory_analysis.md lacks conflict_set detail
  - Good fit: interceptor.md

Suggestions:
  - Consider expanding memory_analysis.md with conflict_set section
```

---

## Refactoring Workflow

For non-trivial refactors spanning multiple sessions, use a **refactor dossier** to track progress, constraints, and decisions.

### Starting a Refactor

```
kt-refactor start <goal description>
```

**Examples**:
- "kt-refactor start extract handler interface into standalone header"
- "kt-refactor start rename dispatch_count to dispatch_id"
- "kt-refactor start comms_mgr to use RAII for buffers"

**Interactive workflow**:
1. You provide the goal
2. I survey the code to identify scope, affected symbols, risks
3. We discuss: "Does ABI need to be preserved?" "What tests should pass?"
4. I draft the dossier, you review and adjust
5. Once approved, we proceed with execution

This creates `.agents/kt/refactors/rf_<slug>.md` with:
- Refactor contract (goal, invariants, verification gates)
- Symbol-level plan (affected symbols, expected files)
- Micro-step checklist

### During the Refactor

Execute in **micro-steps** with compile gates:

1. Make minimal change for one step
2. Compile/test
3. If pass: update dossier, proceed to next step
4. If fail: diagnose and fix before proceeding

### Suspending a Refactor

```
kt-refactor suspend
```

Use when ending a session but refactor is not complete:
- Checkpoints current progress to dossier
- Records: steps completed, gates passed/failed, current state
- Notes next step for resumption
- Sets status to "In Progress"

### Resuming a Refactor

```
kt-refactor resume <slug>
```

**Examples**:
- "kt-refactor resume extract-handler-interface"
- "kt-refactor resume" — if only one active refactor, resumes it

Loads existing dossier with full context:
- Reviews where we left off
- Loads relevant subsystem dossiers
- Confirms next step before proceeding

### Finishing a Refactor

```
kt-refactor finish
```

Use when refactor is complete:
- Verifies all micro-steps are done
- Runs final verification gates
- Updates status to "Done"
- Optionally: updates subsystem dossiers if structure changed
- Archives dossier (remains in `refactors/` for reference)

### Listing All Refactors

```
kt-refactor list
```

Shows all refactors with status:
```
Active refactors:
  rf_extract-handler-interface — In Progress (step 3/5)
  rf_raii-buffer-management — Blocked (waiting for PR #42)

Completed refactors:
  rf_rename-dispatch-count — Done (2026-02-15)
```

### Switching Between Refactors

You can have multiple refactors in progress:

```
kt-refactor suspend                    # pause current
kt-refactor resume other-refactor      # switch to different one
```

**Guidance**:
- Avoid concurrent refactors that touch the same files
- Use "Blocked" status when waiting on external factors
- Prefer sequential for dependent changes

### Example: Refactor Dossier

`.agents/kt/refactors/rf_extract-handler-interface.md`:

```markdown
# Refactor: Extract Handler Interface

## Status
- [x] In Progress

## Objective
Extract `message_handler_base` into a standalone header to reduce coupling.

## Refactor Contract

### Goal
Move `message_handler_base` from `dh_comms.h` to `message_handler_base.h`.

### Non-Goals / Invariants
- ABI compatibility: yes (no changes to class layout)
- API compatibility: yes (include path changes, but symbols unchanged)
- Performance constraints: n/a

### Verification Gates
- Build: `ninja` in build/
- Tests: `ctest -R handler`

## Scope

### Affected Symbols
- `dh_comms::message_handler_base` — move to new header
- `dh_comms::message_handler_chain_t` — update includes

### Expected Files
- `include/dh_comms.h` — remove class, add include [confirmed]
- `include/message_handler_base.h` — new file [confirmed]
- `src/message_handlers.cpp` — update include [hypothesis]

## Plan of Record

### Micro-steps
1. [x] Create `message_handler_base.h` with class definition — Gate: compile
2. [x] Update `dh_comms.h` to include new header — Gate: compile
3. [ ] Remove duplicate definition from `dh_comms.h` — Gate: compile + test
4. [ ] Update downstream includes in omniprobe — Gate: full build

### Current Step
Step 3: Remove duplicate definition

## Progress Log

### Session 2026-03-01
- Completed: Steps 1-2
- Gates: compile passed
- Discovered: `message.h` also needs the base class
- Next: Step 3

## Rejected Approaches
- **Move to `message.h`**: Creates circular dependency with `dh_comms.h`

## Last Verified
Commit: abc123
Date: 2026-03-01
```

---

## File Locations

```
project/
  CLAUDE.md                    # Points to KT, session instructions
  .agents/
    kt_workflows.md            # Full command specifications
    kt_usage.md                # This file
    kt/
      architecture.md          # Always load this
      <subsystem>.md           # Load based on task
      glossary.md              # Domain terms
      sub_<subproject>.md      # Integration dossiers
      refactors/               # Refactor dossiers
        rf_<slug>.md           # One per active/completed refactor

  external/<subproject>/
    .agents/kt/
      architecture.md          # Sub-project overview
      ...
```

---

## Tips

- **Be specific** when loading: "kt-load for interceptor bugfix" beats "kt-load"
- **Don't skip updates**: Run `kt-update` at session end, or use `kt-validate` next time
- **Use refactor dossiers** for multi-session work: they preserve context across sessions

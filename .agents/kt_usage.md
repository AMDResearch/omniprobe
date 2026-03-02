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

  external/<subproject>/
    .agents/kt/
      architecture.md          # Sub-project overview
      ...
```

---

## Tips

- **Be specific** when loading: "kt-load for interceptor bugfix" beats "kt-load"
- **Don't skip updates**: Run `kt-update` at session end, or use `kt-validate` next time
- **Granularity varies**: Exploration needs coarse KT; bugfixes may need fine detail
- **Negative knowledge matters**: Record why approaches don't work, not just what does

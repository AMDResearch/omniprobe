# Knowledge Tree Overview

## What is the Knowledge Tree?

The Knowledge Tree (KT) is a structured documentation system designed for AI-assisted development. It provides persistent, scoped context that AI coding agents can load at the start of a session, reducing the need to repeatedly explore the same code.

Think of it as a "project memory" that helps an AI agent understand your codebase without reading every file each time.

## The Problem It Solves

When working with AI coding assistants on large projects, several issues arise:

1. **Context pollution**: Agents read too many files, filling their context window with irrelevant information and losing focus on the task at hand.

2. **Repeated exploration**: Each session starts fresh. The agent re-discovers the same architecture, patterns, and gotchas that it learned yesterday.

3. **Lost negative knowledge**: When an approach doesn't work, that knowledge disappears. The next session might try the same dead end.

4. **Scope creep**: Without clear subsystem boundaries, agents make changes with unintended ripple effects.

5. **Multi-session work**: Complex refactors spanning multiple sessions lose context between sessions.

## How It Works

### Structure

The Knowledge Tree lives in `.agents/kt/` and contains:

```
.agents/
  kt_overview.md        # This file (concept explanation)
  kt_usage.md           # Quick reference for users
  kt_workflows.md       # Detailed specs for agents
  kt/
    architecture.md     # System overview (always loaded)
    <subsystem>.md      # Per-subsystem dossiers
    glossary.md         # Domain terminology
    sub_<name>.md       # Integration dossiers for sub-projects
    refactors/          # Active and completed refactor dossiers
      rf_<slug>.md
```

### Dossiers

Each subsystem gets a **dossier** — a concise document (~200 lines) containing:

- **Responsibilities**: What this subsystem does
- **Key interfaces**: Important functions/classes with file anchors
- **Invariants**: Rules that must not be broken
- **Known limitations**: Current constraints and technical debt
- **Rejected approaches**: What doesn't work and why (negative knowledge)

Dossiers are **not code mirrors**. They store understanding, not copies of code. They reference code via anchors like `src/handler.cc:142` rather than embedding it.

### Session Workflow

**Starting a session**:
```
kt-load
```
The agent loads `architecture.md` and asks what you're working on, then loads relevant subsystem dossiers.

**During the session**:
Just code. The KT provides context. If it feels too coarse or detailed:
```
kt-reflect
```

**Ending a session**:
```
kt-update
```
The agent reviews changes and updates relevant dossiers with new learnings.

### Refactoring Workflow

For non-trivial refactors that span multiple sessions:

```
kt-refactor start <goal>     # Create refactor dossier interactively
kt-refactor suspend          # Checkpoint progress when pausing
kt-refactor resume           # Continue where you left off
kt-refactor finish           # Complete and archive
kt-refactor list             # See all refactors and their status
```

Refactor dossiers track:
- Goal and constraints (ABI compatibility, tests that must pass)
- Affected symbols and files
- Step-by-step plan with compile gates
- Progress across sessions
- Rejected approaches

## Key Principles

### 1. Scoped Loading
Load only what's needed for the current task. Don't read the entire KT at session start.

### 2. Source Code is Truth
Documentation can be outdated. When the KT conflicts with source code, the code wins. Update the KT accordingly.

### 3. Negative Knowledge Matters
Record structural impossibilities, not anecdotal failures:
- Good: "Approach X violates invariant Y because Z"
- Bad: "Tried X, got error, gave up"

### 4. Task-Relative Granularity
- **Exploration**: Coarse KT (architecture + one subsystem)
- **Bugfixes**: Fine detail (specific functions, edge cases)
- **Refactors**: Full dossier with symbol-level tracking

### 5. Micro-Steps with Gates
For refactors, make small changes and verify each one compiles/passes tests before proceeding. Don't accumulate breakage.

## Sub-projects

Sub-projects (like git submodules) have their own KT in `<subproject>/.agents/kt/`. The top-level KT contains **integration dossiers** (`sub_<name>.md`) that describe how sub-projects connect to the main project.

When working on a sub-project, load both:
1. Top-level architecture + integration dossier
2. Sub-project's own KT

## Maintenance

### Validation
Check for stale dossiers and broken anchors:
```
kt-validate
```

### First-Time Setup
Create the KT structure for a new project:
```
kt-init
```

## Quick Reference

| Command | When | Purpose |
|---------|------|---------|
| `kt-init` | First session | Create KT for new project |
| `kt-load` | Session start | Load context from KT |
| `kt-update` | Session end | Persist learnings |
| `kt-validate` | Maintenance | Check for staleness |
| `kt-reflect` | Mid-session | Assess KT granularity |
| `kt-refactor *` | Refactoring | Multi-session refactor tracking |

See `kt_usage.md` for detailed examples and `kt_workflows.md` for full specifications.

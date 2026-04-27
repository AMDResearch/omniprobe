# Project Memory Overview

Project Memory exists so future sessions do not have to rediscover the same durable truths.

## What Belongs In PM

- stable architecture or document boundaries
- durable decisions
- durable negative knowledge
- important project-specific vocabulary

## When To Update PM

- after substantial work changes the durable understanding of the project
- when a new durable boundary or dependency becomes clear
- when an assumption is corrected in a way that future work must know

## What Stays Out

- raw transcripts
- temporary notes that are not durable
- detailed step-by-step execution logs

## Code-Navigation Units

Code-navigation units are PM units that map the source code rather than the infrastructure or process boundaries of the project.

### What They Contain

Each code-navigation unit covers a logical subsystem and records:

- Key source files and their roles.
- Important types, functions, and data flow paths.
- Invariants that must hold across changes.
- Dependencies on other subsystems or external libraries.

### How They Differ From Infrastructure Units

Infrastructure units are directory-oriented — they describe the repo layout, build system, CI configuration, and similar stable scaffolding. Code-navigation units are subsystem-oriented — they describe how a functional area of the code works. Because source code changes more frequently than infrastructure, code-navigation units have a higher expected update frequency. This is by design: they trade durability for actionability.

### Architecture-First Loading

When starting work on a task, agents follow an architecture-first loading pattern:

1. Load the architecture overview unit to understand the system's top-level structure.
2. Load the code-navigation units for the subsystems relevant to the current task.
3. Load infrastructure units only if the task involves build, deployment, or repo-structure concerns.

This avoids loading unnecessary context and keeps the agent focused on the code that matters.

### When They Need Refreshing

Code-navigation units should be refreshed:

- After source files are added, moved, or renamed within a subsystem.
- After a new subsystem is introduced.
- After a substantial restructuring that changes data flow or key interfaces.

Stale code-navigation units are worse than missing ones, because they actively mislead. When in doubt, verify a unit's anchors against the actual source tree.

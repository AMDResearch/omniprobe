---
name: lessons-forward
description: |
  Package a locally discovered lesson for forwarding to the Agentic Meta
  Project. Use after a session review identifies a finding that generalizes
  beyond this project -- a template gap, missing skill, or structural issue
  that would affect any project using the system.
---

# lessons-forward

## Purpose

Not every process improvement is local. Some findings -- new failure modes, structural problems in the template, missing skill coverage -- generalize to all projects using this system. This skill defines the criteria for deciding what to forward, and the artifact format for doing so.

## Preconditions

- A session review or local proposal exists that contains a finding the agent believes generalizes.
- The agent has read the originating review or proposal.

## Required Reads

1. The originating artifact (session review or local proposal providing the finding).
2. `.agents/improvement/failure-modes.md` -- to check if this is already a known local pattern.
3. `.agents/improvement/forward-to-meta/` -- scan existing forwarded lessons to avoid duplicates.
4. `.agents/policy/guardrails.md` -- to confirm the agent is allowed to create (but not apply) improvement artifacts.

## Procedure

1. **Apply forwarding criteria.** A lesson qualifies for forwarding only if ALL of the following are true:
   - It describes a failure mode, structural gap, or missing capability in the template itself (not in project-specific code).
   - It has been observed in at least one concrete session (not hypothetical).
   - The proposed improvement would apply to any project using the Agentic Meta Project template, not just this one.
   - It is not already captured in an existing forward-to-meta artifact.
2. **If criteria are not met**, stop and report which criterion failed. Do not create an artifact.
3. **Identify the affected template component.** Name the specific file, skill, policy, or structural element in the template that the lesson applies to (e.g., "session-init/SKILL.md", "bootstrap/session-start.md", "workflow dossier schema").
4. **Draft the forwarding artifact.** Write the artifact using the schema below.
5. **Verify no policy violation.** Confirm that no process or policy file in `.agents/` was modified. This skill creates a new file under `.agents/improvement/forward-to-meta/` only.

## Output

Write to `.agents/improvement/forward-to-meta/<date>-<slug>.md`:

```markdown
# Forward to Meta: <title>

**Date:** YYYY-MM-DD
**Origin:** <path to originating session review or local proposal>
**Affected Template Component:** <specific file or structure in the template>

## Observation
<What happened. Cite the specific session or failure mode. 2-4 sentences.>

## Root Cause
<Why the template's current design allowed or caused this. 1-3 sentences.>

## Proposed Improvement
<Specific change to the template. Name the file, section, or skill to modify and describe what the change would be.>

## Generalization Argument
<Why this applies beyond this project. What other project shapes would hit the same issue? 2-3 sentences.>

## Evidence
- Session: <capture path or date>
- Failure mode: <category>
- Recurrence: <one-time | recurring>
```

## Completion Criteria

- All four forwarding criteria were evaluated and passed.
- The artifact names a specific template component, not a vague area.
- The generalization argument explains why the lesson is not project-specific.
- The artifact was written to `.agents/improvement/forward-to-meta/` and no other files were modified.

## Error Handling

- If forwarding criteria are not met, report which criterion failed and do not create an artifact. This is a normal outcome, not an error.
- If the `.agents/improvement/forward-to-meta/` directory does not exist, create it.
- If a near-duplicate already exists in `forward-to-meta/`, stop and report: "Similar lesson already forwarded: <existing file>. Consider updating that artifact instead."
- Do NOT modify any template files, process docs, or policy files. This skill produces a forwarding artifact only. Actual template changes happen in the meta project repository.

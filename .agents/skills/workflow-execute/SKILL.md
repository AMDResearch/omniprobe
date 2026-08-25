---
name: workflow-execute
description: |
  Run an active workflow autonomously under a blocking acceptance gate. Use when
  the user wants a workflow executed unattended, says "execute", "run this
  autonomously", or asks for a headless run. Emits the exact claude invocation,
  registers the Stop hook that gates on acceptance.sh, and records the result.
---

# workflow-execute

## Purpose

Run an active workflow packet to completion in an unattended session, with the packet's
`acceptance.sh` as the mechanical condition for being allowed to stop.

An agent asked whether it is finished will generally say yes. This skill removes the question:
a `command`-type Stop hook runs the acceptance script whenever the agent tries to stop, and
refuses until it exits 0, handing the script's own failure output back as the reason. The agent
is re-driven with a concrete list of what is still unmet.

The gate is deterministic and free -- no model call, no network dependency, and nothing to
adjudicate. It is the same script a human would run.

## Who Performs Which Step

This procedure has two actors, and the split is not a matter of preference. Two of its steps are
denied to an agent by the permission classifier — correctly, because they are exactly the shape a
classifier exists to stop:

| Step | Actor | Why |
|---|---|---|
| 1. Baseline `acceptance.sh` run | agent | Ordinary read-and-run inside the repo. |
| 2. Write the hook settings file | **human** | Writing a file that grants an agent a permission mode is the classifier's central case. An agent authorizing its own unattended run is the thing being prevented. |
| 3. Launch `claude -p ...` | **human** | The launch trusts a directory and starts a session under `--permission-mode auto`. |
| 4. Poll the run | either | Reading output. |
| 5–6. Read the result, record it | agent | Ordinary reads and packet writes. |

**The first unattended launch in a new project therefore requires a human.** An agent that reads
this skill and tries to perform steps 2 and 3 itself will be denied, and if it is inside a
blocking Stop hook at the time it cannot stop either. Plan for the human, rather than discovering
the wall mid-run.

Be precise about *why* it is denied, because the mechanism is not what it looks like. The hook
settings file is eleven lines of innocuous JSON — you would write the same file for an ordinary
interactive session, and writing it in isolation is permitted. It is **denied on intent, not
content**: the classifier reads this skill and the packet's run-log, infers that the file exists
to be paired with `--permission-mode auto`, and stops it.

So this is classifier judgement, not a structural rule, and it is context-sensitive — the same
write succeeds in a session where nothing suggests an unattended launch. That does not make it
avoidable here, and the reason is worth understanding: **the framework's own artifacts are what
make the action legible as dangerous.** The better documented the packet, the more reliably the
denial fires. Do not read an occasional permitted write as evidence that the requirement has
lapsed, and do not go looking for a phrasing that slips past — the classifier is right, and
routing around it is the one move this whole convention exists to prevent.

Once the settings file exists and the directory is trusted, subsequent runs in that project need
no further human action, so the cost is one action per project, not one per run. Pre-granting it
at amplify time was considered and declined: it would hand every amplified repository a standing
authorization for precisely this shape, to save that single action.

Steps below are written in the imperative for whoever is performing them. Where a step is the
human's, it says so.

## Preconditions

- The workflow packet is in `.agents/workflows/active/<workflow-id>/` and has an `acceptance.sh`
  that runs to completion.
- `.agents/hooks/stop-acceptance.sh` exists and is executable.
- The working tree is clean, or its dirty state is understood. `ac_check_write_scope` reports
  what has already been written; starting dirty makes that check partial.

## Required Reads

1. `.agents/workflows/active/<workflow-id>/handoff.md` -- current status and next step.
2. `.agents/workflows/active/<workflow-id>/dossier.md` -- the contract, especially Failure
   Policy, which determines what the agent should do when it cannot proceed.
3. `.agents/state/active-workflows.md` -- confirm no other active workflow shares the write
   scope. Two autonomous runs writing the same files is not a race the framework can resolve.

## Procedure

1. **Run `acceptance.sh` first, by hand.** Record the baseline. If it already exits 0 there is
   nothing to execute, and if it crashes the gate is broken -- fix that before launching a run
   that depends on it.

2. **[human] Write the hook settings file.** It is not committed. Put it outside the repository, or in
   `.untracked/scratch/`, so the hook fires only for this invocation and not for every
   interactive session in the repo:

   ```json
   {
     "hooks": {
       "Stop": [
         {
           "matcher": "*",
           "hooks": [
             {
               "type": "command",
               "command": "bash .agents/hooks/stop-acceptance.sh"
             }
           ]
         }
       ]
     }
   }
   ```

   A Stop hook supplied this way registers and fires correctly; it does not need to be in a
   committed `.claude/settings.json`. If more than one packet is active, set `AMP_ACCEPTANCE`
   in the command to name the one you mean -- otherwise the hook runs every active packet's
   script and blocks unless all of them pass.

3. **[human] Launch the run.** The agent may compose and emit this invocation; running it is the
   human's step. This is the form to use:

   ```
   claude -p "<task instruction>" \
     --settings .untracked/scratch/acceptance-hook.json \
     --permission-mode auto \
     --max-budget-usd <cap>
   ```

   **`--permission-mode auto` and `--max-budget-usd` are mandatory whenever a blocking Stop hook
   is active.** Not recommended -- mandatory. Each closes a distinct failure that has been
   observed in practice:

   - Without `--permission-mode auto`, the agent hits a permission prompt with no human present,
     cannot do the work, and cannot stop either, because the hook keeps refusing. Default
     permissions plus a blocking Stop hook plus nobody watching is a livelock, and it is the
     default configuration, so it happens by omission rather than by choice.
   - Without `--max-budget-usd`, nothing bounds a run that never converges. A Stop hook has no
     built-in iteration cap: a spike observed eight consecutive firings, each a full agent turn,
     ending only when a budget ceiling was hit.

   The budget is a **backstop, not the termination mechanism**. Termination is
   `stop-acceptance.sh`'s no-progress detection: when an iteration's output is byte-identical to
   the previous one, nothing is changing, so it approves and reports `unresolved`. A budget
   cannot tell a livelock from slow progress; it only knows how much has been spent.

4. **Run it detached and poll.** Headless runs take minutes, not seconds. Launch with
   `nohup ... &` and poll -- a short foreground timeout kills the run mid-flight and looks
   exactly like a hang.

5. **Read the result from the packet, not the summary.** When the run ends, check in order:
   - `bash .agents/workflows/active/<workflow-id>/acceptance.sh` -- the ground truth.
   - `.untracked/scratch/acceptance-last.txt` -- the last iteration's output as the hook saw it.
   - The packet's `run-log.md` and `handoff.md`.

   An `unresolved: no progress since previous iteration` approval means the run stopped without
   meeting the criteria. It is a legitimate outcome and must not be read as success.

6. **Record the outcome** in the packet's `run-log.md`: the invocation, the exit status, the
   final acceptance output, and whether the gate approved or gave up. If the gate gave up, say
   which criteria were still failing.

## Do Not Use `/goal` As The Gate

`/goal` is a session-scoped Stop hook and looks like the natural fit. It is not, and the failure
mode is bad enough to be worth stating plainly.

Its hook evaluator asks the model for a structured, schema-constrained response. **On any model
gateway that does not support structured outputs, every evaluation returns HTTP 400.** That is a
portability constraint, not a local quirk -- the same code path fails on any such deployment.

Three properties make it worse than an ordinary outage:

- **It fails open.** The error is non-blocking, so the stop is allowed. The run ends normally,
  exit 0, no error in the output.
- **It is invisible.** Nothing surfaces in stdout or in `--output-format json`. The failure
  appears only in the session transcript JSONL.
- **The result is indistinguishable from success.** You get a session that looks like it ran
  under a goal and enforced a condition, when nothing was ever evaluated.

The `command`-type Stop hook above has none of these dependencies: no model call, no structured
outputs, no gateway involvement, and the block reason carries the acceptance script's own output
straight back to the agent. Prefer it unconditionally.

## Output

- **Location**: No new packet files. Updates go to `.agents/workflows/active/<workflow-id>/run-log.md`
  and `handoff.md`. The hook settings file and `.untracked/scratch/acceptance-last.txt` are
  scratch and are not committed.
- **Format**: A run-log entry following the standard fields, plus the invocation used, verbatim,
  so the run can be reproduced.

## Completion Criteria

- The invocation was emitted with `--settings`, `--permission-mode auto`, and `--max-budget-usd`.
- The run terminated, and the reason it terminated is known: acceptance passed, the gate gave up
  with `unresolved`, or the budget backstop fired.
- `acceptance.sh` was re-run by hand afterwards, and its result -- not the agent's own account of
  the run -- is what is recorded.

## Error Handling

- If `acceptance.sh` is missing, stop. There is nothing to gate on, and a Stop hook with no
  script approves immediately, which is a run with no gate at all rather than an error.
- If the run exhausts its budget, report it as an unfinished run. A budget stop is not a failed
  contract and not a met one; it is an unknown, and the acceptance output says which.
- If the hook never fires, verify the settings file is being read: a bad `--settings` path is
  silently ignored, and the run then looks like a clean, fast success.
- If the agent modified `acceptance.sh` during the run, treat every result from that run as void.
  Check `git diff` on the packet directory before believing an exit 0.

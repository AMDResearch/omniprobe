# Run-Log

Append an entry after every meaningful execution step. This is not optional. If the session is
interrupted, this log is the only record of progress.

## Log Entries

### 2026-09-08 10:05

- **Actor**: claude
- **Planned step**: Turn the incoming seed into a packet, verifying its claims rather than
  accepting another agent's report.
- **Action taken**: Committed the seed unedited, then re-checked every claim at `8de44b0`: absence
  of any GIL call in `src/pyHandler.cc`; `pythonMessageHandler` constructed nowhere; no base class
  at `inc/pyHandler.h:29`; `find_package(Python)` at `src/CMakeLists.txt:51` with no
  `Python::Python` on any link line; undefined `Py*` symbols in the built core library.
- **Result**: success. Every claim held. Measured **13** undefined `Py*` symbols where the seed
  reported 14 — different build, same conclusion; recorded rather than smoothed over.
- **Files touched**: packet files under `.agents/workflows/draft/bf_pyhandler-gil/`
- **Verification**: source reading plus `nm -D` and `ldd` on `build/lib/liblogDuration64.so`. The
  gdb backtraces were not reproduced here — that is Plan Of Record step 1.
- **Criteria impact**: none met. All open by design at draft.
- **Blocker / Risk**: the verification surfaced the finding that shaped the packet — **the GIL fix
  cannot be tested in isolation**, because nothing in the tree can construct the handler, so the
  seed's own suggested acceptance criteria are unreachable by its own patch. That forced a scoping
  decision rather than a two-line bugfix.

### 2026-09-08 10:10

- **Actor**: claude
- **Planned step**: Resolve the scoping fork before writing acceptance criteria.
- **Action taken**: Put the fork to the repository owner: GIL fix plus **plugin** reachability,
  GIL fix plus **core** reachability, or split into a bugfix and a separate feature packet.
- **Result**: owner chose **plugin reachability** — a bridge under `plugins/` using the existing
  `getMessageHandlers` ABI, with the core library unchanged. Recorded in the dossier as a decision,
  and made mechanically observable as AC-6 so a drift into the core fails the gate rather than
  passing quietly.
- **Files touched**: `dossier.md`, `acceptance.sh`
- **Verification**: inspected `plugins/CMakeLists.txt` and `plugins/plugin.h:32` to confirm the ABI
  and that `plugins/` is a flat directory of `.cc` files, and `omniprobe/config/analytics.py` to
  confirm how an analyzer name maps to a `lib_name`. Write scope reflects all three.
- **Criteria impact**: none met.
- **Blocker / Risk**: Open Questions 1–3 remain; 2 (how the Python module is named) is the one
  without which the feature is unusable.

### 2026-09-08 10:40

- **Actor**: claude
- **Planned step**: Readiness check, then promote.
- **Action taken**: Ran the checklist. All structural items passed. The step-3 pattern audit found
  one defect of each direction. **AC-2 was a vacuous pass**: it matched
  `/dispatches?[^0-9]*[2-9]/` anywhere in the output, which a run invoked with `-d 2` satisfies via
  its own `LOGDUR_DISPATCHES=2` environment line while the Python side saw exactly one dispatch —
  on the criterion whose entire purpose is catching the per-instance `Py_Finalize` regression.
  **AC-3 was a false-FAIL risk**: a negative grep of the test script for `Function call to`, which
  breaks the moment the test documents why it must not assert on that string. Replaced both with a
  sentinel contract (`PYHANDLER_ADDR`, `PYHANDLER_DISPATCHES`, `TARGET_STATUS`) that the gate
  compares numerically, and documented it in the dossier so the test author knows what to emit.
- **Result**: READY. Promoted `draft` → `active`, base commit `821c89b`.
- **Files touched**: `acceptance.sh`, `dossier.md`, `handoff.md`, packet directory moved
- **Verification**: each repaired check run against a passing fixture and a decoy carrying
  `LOGDUR_DISPATCHES=2`, the success print, and the prose "target exited 0". All four discriminate
  correctly. Gate runs to completion; AC-6 passes at the base commit, which is correct — it is the
  regression guard for the plugin-not-core scoping decision.
- **Criteria impact**: none met; AC-6 passes as a guard, AC-5 is the judgement criterion.
- **Blocker / Risk**: Open Question 2 — nothing supplies the `module_name` the constructor takes.

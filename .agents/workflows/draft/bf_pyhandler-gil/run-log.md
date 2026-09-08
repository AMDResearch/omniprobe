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

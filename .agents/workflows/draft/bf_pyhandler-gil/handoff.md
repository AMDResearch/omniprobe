# Handoff

**Location**: `.agents/workflows/draft/bf_pyhandler-gil/handoff.md`

## Current Status

Draft, filed 2026-09-08 from an incoming seed. No production code changed.

**This packet will be executed in a fresh session by an agent with none of the filing context**,
so the dossier is written to stand alone. Read it rather than the seed.

The scope was decided by the repository owner on 2026-09-08 and is not open for re-litigation
during execution: **the Python bridge ships as a plugin under `plugins/`, not as a core change.**
AC-6 makes that observable — it fails if libpython appears in `liblogDuration64.so`.

## Last Verified

2026-09-08, at `8de44b0`, in this repository. All of the seed's claims held:

- `src/pyHandler.cc` has `Py_Initialize` (32), `Py_Finalize` (43, 70), `PyDict_New` (74, 103) and
  **no `PyGILState_*` or `PyEval_*` call at all**.
- `pythonMessageHandler` is constructed nowhere: `grep -rn` over `src/ inc/ plugins/` returns only
  its own definition and declaration.
- `inc/pyHandler.h:29` is `class pythonMessageHandler {` — no base class.
- `src/CMakeLists.txt:51` finds Python and `:107` adds its include dirs, but nothing links
  `Python::Python`. `nm -D --undefined-only build/lib/liblogDuration64.so | grep -c ' Py'` → **13**
  undefined `Py*` symbols; `ldd` shows no libpython.

The seed reported 14 undefined symbols at `44547f9`; 13 is what this build shows. Same conclusion.
The gdb backtraces are the filing agent's, on gfx950, and were not reproduced here.

## Next Exact Step

Plan Of Record step 1: reproduce the crash. The shortest path is the spike's proof of concept in
the **IntelliKit sidecar** at `.untracked/omniprobe-extensibility/poc/` — it already contains a
working `py_bridge_plugin.cc`, `handler.py` and `reachable.patch`. Use it to get a message to the
handler and confirm the SIGSEGV before changing anything here.

Build for the node you are on. **A wrong-architecture binary does not error — it silently does not
dispatch**, which would look exactly like "the crash is already fixed".

Then resolve Open Questions 1 and 3 together (they are probably the same question) before writing
the plugin.

## Active Risks / Blockers

- **A wrong-arch build produces a false green on AC-1/AC-2.** Check `rocminfo` and build with a
  matching `-DCMAKE_HIP_ARCHITECTURES` before believing any result.
- **Open Question 2 is unanswered and the feature is unusable without it**: the constructor takes
  a `module_name` that nothing supplies. Decide how a user names the Python module and document it.
- **`tests/run_all_tests.sh` is shared with two other active packets.** Append only your own
  `run_suite` line; do not reformat or reorder.
- Dropping `Py_Finalize()` leaks the interpreter at process exit. That is deliberate and is a
  declared non-goal — do not "fix" it with a per-instance finalize, which is the defect.

## Required Reads Before Resuming

1. This file, then `dossier.md`.
2. `.agents/pm/units/handler-pipeline.md` — plugin loading and handler dispatch.
3. `plugins/plugin.h` and an existing plugin (`plugins/memory_analysis_plugin.cc`) as the shape to
   follow.
4. The seed for the tested patch and the gdb backtraces.

## Proposed Spec Changes

None.

## Scope Amendments

None.

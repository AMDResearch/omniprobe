# Handoff

**Location**: `.agents/workflows/active/bf_pyhandler-gil/handoff.md`

## Current Status

**2026-11-08: implemented, full-suite verification in progress.** Fix, plugin, test (suite 19) and
docs written; the new suite passes 7/7 on gfx90a and fails 7/7 (SIGSEGV) on the unfixed
`pyHandler.cc`. See run-log 2026-11-08.

## Decisions (2026-11-08, resolving Open Questions 1-3)

1. **Wrap, don't derive.** `python_bridge_plugin.cc` holds a `pythonMessageHandler` inside an
   adapter deriving from `dh_comms::message_handler_base`. `pythonMessageHandler` stays free of
   dh_comms types.
2. **Module named by `OMNIPROBE_PYTHON_HANDLER`**: a path to a `.py` file (its directory is put on
   `sys.path`) or a module name resolved through `PYTHONPATH`. Env var because the launcher passes
   the environment through and plugins already configure themselves that way
   (`LOGDUR_LOG_LOCATION`). A launcher flag (`--python-handler`) would be friendlier for agents;
   not done (launcher out of scope) — follow-up.
3. **Visibility is moot**: `pyHandler.cc` is compiled into the plugin and removed from the core
   library, so nothing crosses the core's symbol boundary. This also removed the core's 13
   undefined `Py*` symbols.

Also decided: every dict now carries `kernel` and `dispatch_id` (needed for AC-2: without them
Python cannot tell dispatches apart), and an optional `handleReport(dict)` is called once per
dispatch from the adapter's `report()` (without it a Python handler has no point at which to emit
per-dispatch results, since the interpreter is never finalized and `atexit` never runs).

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

## Step 0 — re-stamp the base commit before anything else

Three packets were promoted together on 2026-09-08, and the promotion commit touched all three
packet directories. A packet's own directory is allowlisted by `ac_check_write_scope`; its
**siblings' are not**. So every one of the three currently reports the other two's files as
out-of-scope writes:

    FAIL  SCOPE  writes outside declared scope: .agents/workflows/active/<another-packet>/...

That is the check working correctly on the wrong subject. Nothing is actually out of scope, and
chasing it by re-stamping all three in turn is circular — whichever is stamped last puts the
others back in range.

**First action on picking this packet up:** set `- Base Commit:` in `dossier.md` to
`git rev-parse HEAD`, commit that one-line change on its own, and re-run `acceptance.sh`. `SCOPE`
returns to `PASS` and stays there, because from then on the only commits in range are this
packet's own.

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

2026-11-08: added `src/CMakeLists.txt` (remove `pyHandler.cc` from the core), `tests/test_kernels/
python_handler_test.cpp` + `tests/test_kernels/CMakeLists.txt` (a kernel with an exact address
count and a device barrier), `docs/usage.md` + `README.md` (document `PythonHandler`; also fixed
their stale "BasicBlockAnalysis = timing with percentile breakdown" line, untrue since
`bf_bba-hardening`). ACs 9-11 added and AC-4/AC-7 amended at the supervisor's direction (AC-7's
`python` banner match had become vacuous: suite 17 is "Python API end to end").

## Follow-ups (not in this packet)

- Interpreter teardown ownership (declared non-goal; interpreter is leaked at exit).
- `--python-handler` launcher flag.
- **Untested: PythonHandler inside a Python host (Triton).** The host's interpreter is reused. If
  the host thread holds the GIL while blocking on kernel completion, completion (`checkinCommsObject`
  → `stop()` joins the processing thread, which waits for the GIL) would deadlock. Not measured.

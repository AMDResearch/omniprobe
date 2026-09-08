# Dossier — bf_pyhandler-gil

## Metadata

- Workflow ID: bf_pyhandler-gil
- Workflow Type: bugfix
- Lifecycle State: active
- Owner / Current Executor: unassigned
- Intended Write Scope: see the `write-scope` block below (canonical)
- Dependencies On Other Active Workflows: shares `tests/run_all_tests.sh` with
  `bf_intern-clone-name` and `bf_exit-status-not-propagated` — see § Dependencies
- Base Commit: 821c89b97cc13ae2509e3ceecff2790af014017a

```write-scope
src/pyHandler.cc
inc/pyHandler.h
plugins/python_bridge_plugin.cc
plugins/CMakeLists.txt
omniprobe/config/analytics.py
tests/test_python_handler.sh
tests/python_handler/
tests/run_all_tests.sh
```

## Objective

A Python function can receive instrumented GPU messages from a real multi-dispatch run, and the
run completes without crashing. Concretely: a Python handler module named through the existing
analyzer configuration receives address messages from **more than one dispatch** and leaves
evidence of its own that the test asserts on.

Today this is impossible twice over — the handler segfaults the moment a message arrives, and
even fixed, nothing in the tree can construct it.

## Background / Context

Filed as a seed on 2026-09-08 by an agent working in the `intellikit` sidecar
(`.agents/workflows/seeds/bf_pyhandler-gil.md`), which found it while running IntelliKit's W5
extensibility spike (`iv_omniprobe-extensibility`) against pinned git objects of this repository.
The spike deliberately made **no change here**, which is why it arrived as a seed rather than a
branch. It ships a tested patch.

Every claim was **re-verified in this repository at `8de44b0`** before this packet was written.

### Defect 1 — the Python C-API is called with no GIL

Messages are delivered on a `dh_comms` worker thread. The first `PyDict_New()` dereferences
thread state that thread does not have. Confirmed by gdb backtrace on MI350X / ROCm 7.2.0:

    Thread 9 "simple_memory_a" received signal SIGSEGV
    #0  PyDict_New () from /lib64/libpython3.12.so.1.0
    #1  pythonMessageHandler::addressMessage(void*)
    #3  dh_comms::message_handler_chain_t::handle(dh_comms::message_t const&)
    #4  dh_comms::dh_comms::processing_loop(bool)

Verified here: `src/pyHandler.cc` contains `Py_Initialize` (line 32), `Py_Finalize` (43, 70) and
`PyDict_New` (74, 103), and **no `PyGILState_*` or `PyEval_*` call anywhere**.

### Defect 2 — the destructor finalizes the interpreter, once per instance

Same missing-GIL crash on teardown (`~pythonMessageHandler` → `Py_FinalizeEx`). **And even with
the GIL held it would still be wrong:** a handler is constructed per dispatch, so finalizing in
the destructor tears the process-wide interpreter down after the first kernel and breaks every
later one. This is why AC-2 requires more than one dispatch — a single-kernel test cannot see it.

### The class is unreachable regardless, which is why this is not a two-line packet

Fixing the GIL is necessary but not sufficient for anyone to *use* it. Verified at `8de44b0`:

| Claim | Verification |
|---|---|
| constructed nowhere | `grep -rn pythonMessageHandler src/ inc/ plugins/` returns only its own definition and declaration |
| derives from nothing | `inc/pyHandler.h:29` is `class pythonMessageHandler {` — no base, so `append_handler` cannot take it |
| no libpython on the link line | `src/CMakeLists.txt:51` calls `find_package(Python COMPONENTS Development)` and `:107` adds `${Python_INCLUDE_DIRS}`, but nothing links `Python::Python` |
| the library carries unresolved `Py*` | `nm -D --undefined-only build/lib/liblogDuration64.so \| grep -c ' Py'` → **13**; `ldd` shows no libpython |

It links and loads only because nothing calls into it. (The seed reported 14 undefined symbols at
`44547f9`; 13 is measured here at a different build. Same conclusion, and the discrepancy is
recorded rather than smoothed over.)

**So no test can exercise the GIL fix in isolation** — there is no way to get a message to the
handler. That is the reason this packet includes reachability rather than being the seed's
`+24 −1` patch alone.

### Scoping decision — plugin, not core

Decided by the repository owner, 2026-09-08. The Python bridge ships as **one more plugin** under
`plugins/`, using the existing ABI (`LOGDUR_HANDLERS` → `dlopen` → `getMessageHandlers`, per
`plugins/plugin.h:32`), exactly as `libMemAnalysis64.so` and `libBasicBlocks64.so` do.

Rejected: linking `Python::Python` into the core `liblogDuration64.so` and putting the adapter in
`src/`. That makes every consumer of the core library depend on libpython, for a feature most
consumers do not use.

The IntelliKit spike already proved this shape works out-of-tree in about 100 lines: real GPU
addresses from an instrumented kernel reached a Python function, 1024 successful calls across two
kernels, exit 0. **The mechanism is sound; it is the wiring that was never finished.**

Note `plugins/` is a flat directory of `.cc` files built from `plugins/CMakeLists.txt`, not a
directory-per-plugin, so the new plugin is `plugins/python_bridge_plugin.cc` plus a target in that
CMakeLists. To be selectable as `-a <name>`, it also needs an entry in `omniprobe/config/
analytics.py`, which is the list `omniprobe` reads to map an analyzer name to a `lib_name`.

## Contract

Make a Python handler work end to end: fix the GIL and interpreter-lifetime defects in
`src/pyHandler.cc`, and provide the minimum reachability — a plugin adapter, its linkage, and a
way to name the module — for a test to prove it.

## Acceptance Criteria

- **AC-1**: A Python module named through the analyzer configuration receives at least one
  address message from an instrumented kernel.
- **AC-2**: It receives messages from **more than one dispatch** in a single run. This is the
  criterion that catches the per-instance `Py_Finalize` regression; a single-kernel test cannot.
- **AC-3**: The Python side leaves **evidence of its own** — the test asserts on payload values
  written by the Python handler, not on `pyHandler.cc`'s `"Function call to … succeeded!"` print,
  which fires whenever `PyObject_CallObject` returns non-NULL, including for a Python function
  that ignores its argument entirely.
- **AC-4**: The instrumented target's **real** exit status is 0. Check the target directly rather
  than trusting `omniprobe`'s exit code, which is unreliable until
  `bf_exit-status-not-propagated` lands.
- **AC-5**: `src/pyHandler.cc` acquires the GIL on every path that touches the Python C-API, and
  releases it on every exit path including exceptional ones. **[judgement]** — reason: this is a
  claim about all paths through the source, including a `throw` in the `!pDict` branch that no
  test in this packet provokes. AC-1 and AC-2 establish that the common paths work; whether the
  exceptional one leaks the GIL is decided by reading the code.
- **AC-6**: The core library is unchanged in its dependencies: `ldd` on `liblogDuration64.so`
  still shows no libpython. This is the scoping decision made observable — it fails if the fix
  drifts into the core.
- **AC-7**: The new suite is registered in `tests/run_all_tests.sh` and runs as part of it.
- **AC-8**: `tests/run_all_tests.sh` reports every suite passed, 0 failed, 0 skipped.

## Failure Policy

`stop`. In particular, if the plugin route turns out to require a core change after all, stop and
report rather than quietly linking libpython into `liblogDuration64.so` — that reverses an
explicit owner decision and AC-6 is there to catch it.

## Scope

- The GIL and interpreter-lifetime fixes in `src/pyHandler.cc` (the seed's tested patch is the
  starting point, not necessarily the final form).
- Whatever `inc/pyHandler.h` needs for the plugin to construct the handler — visibility, and a
  base class if the adapter does not wrap it instead.
- A new plugin `plugins/python_bridge_plugin.cc` and its target in `plugins/CMakeLists.txt`,
  linking `Python::Python`.
- An analyzer entry in `omniprobe/config/analytics.py`.
- A test with a Python handler fixture, and its registration.

## Non-Goals

- **Correct interpreter teardown.** Dropping `Py_Finalize()` leaks the interpreter at process
  exit. That is the intended trade: a per-instance finalize is *incorrect*, and a correct teardown
  needs an owner with process lifetime — a refcount or a `std::once`-guarded singleton — which is
  a design decision, not a bug fix. Record it as a follow-up.
- Linking libpython into the core library. Explicitly rejected above; AC-6 enforces it.
- A general Python analysis framework — argument marshalling beyond what exists, result schemas,
  or a Python-side API. This packet makes the existing mechanism reachable and correct, nothing
  more.
- `bf_exit-status-not-propagated`. Independent defect, separate packet. AC-4 works around it by
  checking the target's status directly rather than waiting for it.

## Constraints and Assumptions

- **Requires a GPU.** Unlike its companion packet, this one needs a real instrumented dispatch.
  Build for the node you are on: `-DCMAKE_HIP_ARCHITECTURES=gfx950` on MI350X, `gfx90a` on MI210.
  A binary built for the wrong architecture **does not error — it silently does not dispatch**,
  which has manufactured phantom defects in this repository twice.
- The filing agent's evidence was gathered on gfx950; this session's node is gfx90a. Neither is
  privileged, but record which one a result came from.
- A latent classifier bug in `tests/run_all_tests.sh:59` marks a suite *skipped* if the string
  `SKIP` appears anywhere in its output. The new test must not emit it.
- This repository is public: no personal absolute paths in tracked files.

## Dependencies

None blocking. `bf_exit-status-not-propagated` is **related but not required** — AC-4 is worded to
work regardless of whether it has landed. If it has, the check can be simplified.

**Shared-file coordination.** Three active packets append a `run_suite` line to
`tests/run_all_tests.sh`. The rule is: **each appends only its own line and edits no other.**
Executed in separate sessions, that is append-only and conflict-free. Do not reformat or reorder.

## Plan Of Record

1. **Reproduce.** Build the out-of-tree reachability enough to get a message to the handler and
   confirm the SIGSEGV. The spike's proof of concept is the shortest path — see § References.
2. **Apply the GIL and lifetime fixes** to `src/pyHandler.cc`.
3. **Build the plugin**: `plugins/python_bridge_plugin.cc` with an adapter deriving from
   `dh_comms::message_handler_base`, a `getMessageHandlers` entry point, and `Python::Python` on
   its link line. Add the analyzer entry so `-a` can name it.
4. **Verify AC-6 immediately after step 3** — check `ldd liblogDuration64.so` before going
   further. It is much cheaper to catch libpython leaking into the core here than at the end.
5. **Add the test**: a Python handler fixture that writes evidence, and a script asserting on that
   evidence across two dispatches.
6. **Verify**: new suite, then full `tests/run_all_tests.sh` on matching hardware.
7. **Record the follow-up**: interpreter teardown ownership.

## Verification Strategy

| Criterion | Check |
|---|---|
| AC-1 | run the fixture; assert the Python handler's evidence file exists and is non-empty |
| AC-2 | assert the evidence records **two distinct** dispatch or kernel identities |
| AC-3 | assert on payload **values** written by the Python side, never on `pyHandler.cc`'s success print |
| AC-4 | run the instrumented target directly and assert `$? == 0`, independent of omniprobe's status |
| AC-5 | `[judgement]` — read `src/pyHandler.cc` for GIL acquisition and release on all paths |
| AC-6 | `ldd` the built core library; assert no libpython |
| AC-7 | **behavioural**: require a `Suite <n>: …python…` banner in the `run_all_tests.sh` output |
| AC-8 | `tests/run_all_tests.sh` exits 0 **and** the tally reads `Suites skipped: 0` |

### The sentinel contract the test must satisfy

`acceptance.sh` anchors on three literals that `tests/test_python_handler.sh` must emit, one per
line, at column 0:

    PYHANDLER_ADDR=<0xhex>       one per address value the PYTHON side received
    PYHANDLER_DISPATCHES=<n>     distinct dispatches the Python side observed
    TARGET_STATUS=<n>            the instrumented target's OWN exit status

This is prescribed rather than left open because every looser formulation tried while writing the
gate was either vacuous or false-FAILing:

- **AC-2 must compare a number, not match a pattern.** A first version matched
  `/dispatches?[^0-9]*[2-9]/` anywhere in the output — which a run invoked with `-d 2` satisfies
  through its own `LOGDUR_DISPATCHES=2` environment line while the Python side saw exactly one
  dispatch. Verified 2026-09-08 that a normal run prints `LOGDUR_DISPATCHES=all`, so the collision
  needs only a test that passes a count.
- **AC-3 must not be a negative grep.** The natural check — fail if the test script mentions
  `Function call to` — would false-FAIL the moment the test *documents* why it must not assert on
  that string, and the better the test is commented the likelier that is. Assert the presence of
  real address values instead.

AC-3 exists because of a specific trap the filing agent hit: `pyHandler.cc` prints
`"Function call to … succeeded!"` whenever `PyObject_CallObject` returns non-NULL. A Python
function with `def handleAddressMessage(d): pass` satisfies that print completely while doing
nothing, so asserting on it would pass against a handler that ignores every message. Address
values cannot be produced that way.

AC-7 is behavioural for the same reason as in the companion packets: a grep of
`run_all_tests.sh` built from the test's own path components matches the untouched file. Verified
2026-09-08.

## References

- `.agents/workflows/seeds/bf_pyhandler-gil.md` — the originating seed, committed unedited,
  including the tested `+24 −1` patch and both gdb backtraces.
- The spike's proof of concept, in the **IntelliKit sidecar** (not this repo):
  `.untracked/omniprobe-extensibility/poc/` — `py_bridge_plugin.cc`, `handler.py`,
  `reachable.patch`, `run.log`, `evidence.log`; write-up with build commands at
  `.agents/workflows/*/iv_omniprobe-extensibility/recommendation.md`.
- `src/pyHandler.cc:32,43,70,74,103`; `inc/pyHandler.h:29`; `src/CMakeLists.txt:51,107`;
  `plugins/plugin.h:32` (`getMessageHandlers` ABI); `omniprobe/config/analytics.py`.
- `.agents/pm/units/handler-pipeline.md` — PM unit covering plugin loading and handler dispatch.

## Open Questions

1. **Does the adapter wrap `pythonMessageHandler`, or does the class start deriving from
   `message_handler_base`?** Wrapping keeps the core class untouched and is the smaller change;
   deriving is tidier but changes a public header. Either satisfies the ACs. Decide at step 3 and
   record the reason.
2. **How is the Python module named?** The constructor takes a `std::string& module_name`, but
   nothing supplies one. An environment variable is the obvious route and matches how
   `LOGDUR_HANDLERS` already works, but it is unspecified. Decide and document it — a feature
   nobody can configure is not reachable in the sense this packet promises.
3. Is `-fvisibility=hidden` on the core library an obstacle to the plugin constructing the
   handler? If the adapter lives in the plugin and the handler class stays in the core, the symbol
   must be exported. This may settle Open Question 1 by itself.

# Seed — `bf_pyhandler-gil`

**Type:** `bf_` (bug fix)
**Filed:** 2026-09-08, by an agent working in the `intellikit` sidecar
**Status:** seed — not yet a packet

## One line

`pythonMessageHandler` segfaults the moment a message reaches it, because it never acquires the
GIL; and its destructor finalizes the interpreter once per dispatch. Both are small, and a
tested patch is included below.

## Why this is being filed from outside the repo

IntelliKit's W5 spike (`iv_omniprobe-extensibility`) asked whether an agent could author an
Omniprobe analysis in **Python** rather than C++ — which turns on whether
`inc/pyHandler.h`'s `pythonMessageHandler` works end to end. It does not, for two reasons that
are invisible to code reading and certain the moment a message arrives.

The spike deliberately made **no change to this repository**: it read pinned git objects, built
in a throwaway `/tmp` copy, and did the reachability work in an out-of-tree plugin. That is why
this arrives as a seed rather than a branch.

## The defects

Both confirmed by gdb backtrace on an MI350X (gfx950) node under ROCm 7.2.0, against
`src/pyHandler.cc` as of `44547f9` — **unchanged since**, and the patch below applies cleanly at
`8de44b0`.

### 1. `addressMessage` / `timingMessage` call the Python C-API with no GIL

Messages are delivered on a `dh_comms` worker thread. The first `PyDict_New()` dereferences
thread state that thread does not have.

```
Thread 9 "simple_memory_a" received signal SIGSEGV
#0  PyDict_New () from /lib64/libpython3.12.so.1.0
#1  pythonMessageHandler::addressMessage(void*)
#2  <handler adapter>::handle(dh_comms::message_t const&)
#3  dh_comms::message_handler_chain_t::handle(dh_comms::message_t const&)
#4  dh_comms::dh_comms::processing_loop(bool)
```

### 2. `~pythonMessageHandler` calls `Py_Finalize()` with no GIL, once per instance

Same missing-GIL crash, on the teardown path. **And even with the GIL taken it would still be
wrong**: a handler is constructed per dispatch, so finalizing in the destructor tears the
process-wide interpreter down after the first kernel and breaks every later one.

```
Thread 5 "simple_memory_a" received signal SIGSEGV
#0  Py_FinalizeEx () from /lib64/libpython3.12.so.1.0
#1  pythonMessageHandler::~pythonMessageHandler()
#2  <handler adapter>::~<handler adapter>()
#3  dh_comms::message_handler_chain_t::clear()
```

### 3. Not a GIL bug, but it is why nobody noticed — `omniprobe` reports exit 0 on a crashed target

Both crashes above are **invisible through the CLI**: `omniprobe … -- app` returned `0` while
the child dumped core. It only surfaced by extracting the environment with `-e/--env-dump` and
running the target directly, which returned 139. Any CI shelling out to `omniprobe` currently
scores a segfaulting run as a pass.

This is a separate defect with a separate fix and probably wants its own seed — noted here so
it is not lost, not because it belongs in the same change.

## Also worth knowing: the class is unreachable regardless

Fixing the GIL is necessary but not sufficient for anyone to *use* this. At `44547f9`:

- `pythonMessageHandler` is **constructed nowhere** — `git grep pythonMessageHandler -- src inc`
  returns only `src/pyHandler.cc` and `inc/pyHandler.h`.
- It **derives from nothing**, so `append_handler` cannot take it, while all eight real handlers
  derive from `message_handler_base` or `kdb_message_handler_base`.
- `src/CMakeLists.txt` calls `find_package(Python COMPONENTS Development)` and adds
  `${Python_INCLUDE_DIRS}`, but **no libpython reaches the link line**. `liblogDuration64.so`
  carries 14 undefined `Py*` symbols and `ldd` shows no libpython. It links and loads only
  because nothing calls into it.
- `-fvisibility=hidden` means nothing outside the library could construct it either.

So a complete fix is: this patch, **plus** linking `Python::Python`, **plus** an adapter deriving
from `message_handler_base`, **plus** a way to name the module. The spike did the last three in
an out-of-tree plugin — about 100 lines — and with them the path **works**: real GPU addresses
from an instrumented kernel reached a Python function, 1024 successful calls across two kernels,
exit 0. So the mechanism is sound; it is the wiring that was never finished.

Worth deciding as part of scoping: is the intended home for this the existing **plugin ABI**
(`LOGDUR_HANDLERS` → `dlopen` → `getMessageHandlers`, per `plugins/plugin.h`)? A Python bridge
shipped as one more plugin under `plugins/` would need no change to the core at all, and would
match how `libMemAnalysis64.so` and friends already work.

## The patch (tested)

Fixes 1 and 2 only. Applies cleanly at `8de44b0`; `+24 −1`.

```diff
--- a/src/pyHandler.cc
+++ b/src/pyHandler.cc
@@ -57,20 +57,38 @@ pythonMessageHandler::pythonMessageHandler(std::string& module_name)
         std::cerr << "Cannot find function '" << "handleTimeMessage" << "'!" << std::endl;
         throw std::runtime_error(std::string("Failed to find handleTimeMessage!"));
     }
+
+    // Py_Initialize() leaves the GIL held by the constructing thread. Messages
+    // are delivered on a different thread (dh_comms::dh_comms::processing_loop),
+    // so release it here or that thread can never acquire it.
+    if (PyGILState_Check())
+        PyEval_SaveThread();
 }
 
 pythonMessageHandler::~pythonMessageHandler()
 {
+    // Runs on a dh_comms worker thread via message_handler_chain_t::clear(),
+    // which holds no GIL; every call below needs it.
+    PyGILState_STATE gil = PyGILState_Ensure();
     if (pAddressFunc_)
         Py_DECREF(pAddressFunc_);
     if (pTimingFunc_)
         Py_DECREF(pTimingFunc_);
     if (pModule_)
         Py_DECREF(pModule_);
-    Py_Finalize();
+    PyGILState_Release(gil);
+    // Deliberately NOT Py_Finalize(): one handler is constructed per dispatch,
+    // so finalizing here tears the interpreter down after the first kernel and
+    // breaks every later one. The interpreter is process-wide; let it outlive
+    // the handler.
 }
 void pythonMessageHandler::addressMessage(void *address)
 {
+    // Called on a dh_comms worker thread that holds no GIL. Without this,
+    // the very first PyDict_New() below segfaults.
+    PyGILState_STATE gil = PyGILState_Ensure();
+    struct gil_guard { PyGILState_STATE s; ~gil_guard() { PyGILState_Release(s); } } guard{gil};
+
     PyObject* pDict = PyDict_New();
     if (!pDict) {
         PyErr_Print();
@@ -100,6 +118,11 @@ void pythonMessageHandler::addressMessage(void *address)
 
 void pythonMessageHandler::timingMessage(uint64_t time)
 {
+    // Called on a dh_comms worker thread that holds no GIL. Without this,
+    // the very first PyDict_New() below segfaults.
+    PyGILState_STATE gil = PyGILState_Ensure();
+    struct gil_guard { PyGILState_STATE s; ~gil_guard() { PyGILState_Release(s); } } guard{gil};
+
     PyObject* pDict = PyDict_New();
     if (!pDict) {
         PyErr_Print();
```

Two notes on the patch, for whoever turns this into a packet:

- **Dropping `Py_Finalize()` leaks the interpreter at process exit.** That is the intended
  trade: a per-instance finalize is incorrect, and a correct teardown needs an owner with
  process lifetime — likely a refcount or a `std::once`-guarded singleton — which is a design
  decision rather than a bug fix, so it was left out.
- The `gil_guard` struct keeps the release on every path, including the `throw` in the
  `!pDict` branch. A raw `PyGILState_Release` at the end of the function would leak the GIL
  whenever that throw fires.

## Suggested acceptance criteria

1. An instrumented multi-dispatch run with a Python handler completes with the target's **real**
   exit status 0 — check the target directly, not `omniprobe`'s exit code, until defect 3 is fixed.
2. A Python handler receives messages from **more than one dispatch** — this is what catches the
   per-instance `Py_Finalize` regression, and a single-kernel test will not.
3. The Python side leaves evidence of its own: assert on payload values written by the handler,
   not on `pyHandler.cc`'s "Function call to … succeeded!" print, which fires whenever
   `PyObject_CallObject` returns non-NULL — including for a Python function that ignores its
   argument entirely.

## Reproducing

The spike's proof of concept, including a ready-made plugin and Python handler, is in the
IntelliKit sidecar at
`.untracked/omniprobe-extensibility/poc/` — `py_bridge_plugin.cc`, `handler.py`,
`reachable.patch`, `run.log`, `evidence.log`. The full write-up with build commands is
`.agents/workflows/*/iv_omniprobe-extensibility/recommendation.md` in that same sidecar.

Build note for this node: it is **gfx950**, so `-DCMAKE_HIP_ARCHITECTURES=gfx950`. The README
quickstart's `gfx90a` is right for the MI210 nodes but produces a test binary that segfaults
standalone here. Full build was 17s.

# Artifacts — bf_pyhandler-gil

## Inputs

| Item | Where | What it is |
|---|---|---|
| Originating seed | `.agents/workflows/seeds/bf_pyhandler-gil.md` | Incoming report, committed unedited. Carries the tested `+24 −1` patch and both gdb backtraces. |
| Spike proof of concept | IntelliKit sidecar, `.untracked/omniprobe-extensibility/poc/` | `py_bridge_plugin.cc`, `handler.py`, `reachable.patch`, `run.log`, `evidence.log`. Demonstrated 1024 successful Python calls across two kernels, out of tree. |

## Verified in this repository at `8de44b0`

    src/pyHandler.cc:32,43,70,74,103   Py_Initialize / Py_Finalize x2 / PyDict_New x2
                                       ... and no PyGILState_* or PyEval_* anywhere
    inc/pyHandler.h:29                 class pythonMessageHandler {      <- no base class
    grep -rn pythonMessageHandler src/ inc/ plugins/   -> definition and declaration only
    src/CMakeLists.txt:51              find_package(Python COMPONENTS Development)
    src/CMakeLists.txt:107             ${Python_INCLUDE_DIRS}            <- includes only
    nm -D --undefined-only build/lib/liblogDuration64.so | grep -c ' Py'  -> 13
    ldd build/lib/liblogDuration64.so | grep -ci python                  -> 0

The seed reported 14 undefined `Py*` symbols at `44547f9`; this build shows 13. Recorded because
the number differs, not because the conclusion does.

## Decision recorded

**Plugin, not core** — repository owner, 2026-09-08. Rejected linking `Python::Python` into
`liblogDuration64.so`, which would make every consumer of the core library depend on libpython for
a feature most do not use. Enforced mechanically by AC-6.

## Still to be produced

- A reproduction of the SIGSEGV in this repository (the backtraces are the filing agent's, on
  gfx950).
- The plugin, its analyzer config entry, and the answer to "how is the Python module named".
- A Python handler fixture that writes its own evidence, and a test asserting on that evidence
  across two dispatches.
- A `run_all_tests.sh` transcript on architecture-matched hardware.

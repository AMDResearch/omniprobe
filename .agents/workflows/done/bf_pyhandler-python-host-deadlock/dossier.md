# Dossier: bf_pyhandler-python-host-deadlock

## Metadata

- Workflow ID: bf_pyhandler-python-host-deadlock
- Workflow Type: bugfix
- Lifecycle State: done
- Owner / Current Executor: opdisp (worker), supervised
- Intended Write Scope:
- Dependencies On Other Active Workflows: none
- Base Commit: bdd1bd3

```write-scope
src/interceptor.cc
src/comms_mgr.cc
inc/interceptor.h      # amended 2026-11-09 — the check-in queue lives in hsaInterceptor
src/pyHandler.cc
inc/pyHandler.h
tests/
docs/usage.md
```

## Objective

Rene (2026-11-09, deferred decisions): "Omniprobe Python handler inside a Python host: run tests to
determine if this is an issue." It is: PythonHandler deadlocks when the host program is a Python
interpreter that holds the GIL while it submits GPU work, which Triton's launcher does.

## Background (measured 2026-11-09, gfx950, ROCm 7.2.0, build `bdd1bd3`)

- Triton host (`add_kernel` launched 3× back to back, venv Python 3.12), `-a PythonHandler`:
  hangs after the first instrumented dispatch (timeout 300 s, 0 reports). Same script with
  `-a MemoryAnalysis`: completes. 50 and 200 launches: same hang.
- ctypes host, `PyDLL` (GIL held for the call): hangs even for a 2-wave kernel; `CDLL` (GIL
  released): completes with exact counts on Python 3.12 and 3.9.
- gdb on both hangs shows one cycle:
  1. host thread holds the GIL, submits a packet (Triton `hipModuleLaunchKernel`, or a blit for
     `hipMemcpy`) → `doPackets` → `fixupPacket` → waits for `hsaInterceptor::mutex_`;
  2. the signal runner holds `mutex_` in `signalCompleted` (`src/interceptor.cc:456`) and calls
     `comms_mgr::checkinCommsObject` (`src/comms_mgr.cc:88`, which also holds the comms_mgr mutex)
     → `dh_comms::stop()` joins the processing thread;
  3. the processing thread is in `pythonMessageHandler::addressWave` → `PyGILState_Ensure`.
- Also measured, not deadlocks: with a Python thread busy running bytecode, a run that takes 0.9 s
  takes 11 s on Python 3.12 and 120 s on 3.9 (per-message GIL hand-off); a plugin built against
  libpython3.12 runs inside a 3.9 host by symbol interposition (worked here; an ABI hazard).

## Contract

- No lock that the dispatch path takes (`hsaInterceptor::mutex_`, the comms_mgr mutex) is held
  while omniprobe waits for a dh_comms processing thread or a handler's report/destructor.
- One case stays a deadlock by nature: the host holds the GIL while it waits for an instrumented
  kernel whose dh_comms buffers fill (the kernel needs the handler, the handler needs the GIL).
  It is documented, and omniprobe says so on stderr instead of hanging silently.
- Handler results are unchanged (exact counts).

## Acceptance Criteria

Decided by `tests/test_python_host.sh` (named checks).

- **AC-1**: Triton host, 3 back-to-back launches of `add_kernel` (4096 elements), PythonHandler:
  finishes within 180 s with exit 0, 3 reports, 12288 lanes each, handler in the host's
  interpreter. Fails before (hang).
- **AC-2**: ctypes `PyDLL` host (GIL held across launch, sync and memcpy), 3 dispatches of a
  2-wave kernel: finishes, exact lanes per dispatch. Fails before (hang).
- **AC-3**: ctypes `CDLL` host on Python 3.12 and on Python 3.9, 3 dispatches whose buffers fill
  while running: exact lanes. Regression guard (passes before).
- **AC-4**: ctypes `CDLL` host with a concurrently busy Python thread: exact lanes. Regression
  guard (passes before; its slowness is reported, not asserted).
- **AC-5**: `PyDLL` host whose kernel fills its buffers: within 60 s stderr carries
  `omniprobe: WARNING: PythonHandler has waited` naming the GIL. Fails before (silent hang).
- **AC-6**: suite registered; full suite passes on this node (suites 3–5 N/A on gfx950).
- **AC-7** `[WEAK: text presence]`: `docs/usage.md` PythonHandler section documents the
  host-holds-GIL limitation.

## Non-Goals

Batching GIL acquisition (the busy-thread slowdown); building the plugin per host Python version.
Both are reported as follow-ups.

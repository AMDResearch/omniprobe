# Run Log — bf_faulted-dispatch-hang

### 2026-11-08

- Reproduced the hang (see dossier § Background). Bare 0.24 s exit 3; under omniprobe timeout at 60 s.
- Fix: `signal_runner` keeps completing dispatches after shutdown, but abandons the rest (warning
  naming each kernel; comms objects leaked on purpose) once none has completed for 3 s.
  `hsaInterceptor::abandonPendingSignals()` added.
- Also fixed while there: `getPendingSignals` took no lock. `lock_guard<std::mutex> lock(mutex);`
  is a function declaration (`mutex` names the type under `using namespace std`), so
  `pending_signals_` was iterated unlocked while dispatch threads inserted into it. Now locks
  `mutex_`, as `signalCompleted` and `hasPendingSignals` do. Not covered by a failing test (a data
  race; no reproduction attempted).
- Suite 20 (`tests/test_faulted_dispatch.sh`, kernel `fault_test`). Fixed: 3/3 PASS (exit 3 after
  3-4 s in timing and in `-i -a AddressLogger` mode, warning names `fault_kernel`; `--no-fault`
  exit 0 in 1 s, no warning). Unfixed `interceptor.cc`/`.h` (HEAD versions rebuilt): both fault
  cases exit 124 at the 30 s timeout, no warning; no-fault case passes.

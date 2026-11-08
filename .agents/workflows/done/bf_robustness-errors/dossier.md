# Dossier — bf_robustness-errors

## Metadata

- Workflow ID: bf_robustness-errors
- Workflow Type: bugfix (bundle, supervisor 2026-11-08: items 2-5)
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Base Commit: 2b260f9

```write-scope
src/interceptor.cc
inc/interceptor.h
src/utils.cc
plugins/plugin.h
plugins/python_bridge_plugin.cc
omniprobe/omniprobe
tests/test_robustness.sh
tests/run_all_tests.sh
docs/usage.md
```

## Defects and fixes

1. **`-a <nonexistent .so>` hung** (measured: until killed). gdb: `handlerManager::setHandlers`
   called `exit(1)` on the main thread during interceptor construction (inside `getInstance()`,
   holding `singleton_mutex_`); `exit` ran rocprofiler's finalizer, which called omniprobe's tool
   finalizer, which waited on the same mutex. Fix: `fatalHandlerError` prints and `_exit(1)`s;
   the launcher also rejects a nonexistent `.so` path before starting.
2. **A `.so` without `getMessageHandlers` was silently ignored; an unknown analyzer name was
   "Ignoring."** — both ran the default handlers, exit 0. Now errors (exit 1).
3. **Unusable PythonHandler module → Heatmap, exit 0.** New optional plugin entry point
   `omniprobeValidateHandlers(std::string&)` (plugins/plugin.h), called right after loading;
   PythonHandler imports and checks the module there. Launcher checks unset / missing `.py`.
4. **kernelDB failure (no `ROCM_PATH`, no `/opt/rocm`)** — worse than the reported silent `[]`:
   `scanCodeObject` threw inside `fixupPacket`, `doPackets`' catch skipped writing the packet,
   and the **instrumented dispatch was silently dropped** (python_handler_test: 2048 wrong
   results). kernelDB is a submodule (not changed): it reads `ROCM_PATH` once at load, default
   `/opt/rocm`. Fixes: (a) launcher resolves ROCm (ROCM_PATH if it has llvm-objdump, the ROCm
   the core library links against, hipconfig, rocminfo/hipcc on PATH, /opt/rocm-*, /opt/rocm),
   sets ROCM_PATH for the child, errors for `-i` if none; (b) a scan failure is caught at the
   scan, reported once as `omniprobe: ERROR`, counted in the exit summary, and the clone runs
   without attribution; (c) any exception while instrumenting a dispatch now submits the
   original packet ("running it uninstrumented") instead of dropping it.
5. **Exit-summary split** (`src/interceptor.cc` destructor). Moving the print after the joins and
   making it one `write(2)` did not fix it (still 22/24 split under 24 concurrent runs): the
   cause was the launcher, which forwarded the child's stdout and stderr one line per select()
   alternately, so a stdout line ("Ending kernelDB") landed inside the stderr summary. The
   launcher now forwards raw chunks as written (stdout and stderr stay separate). Both changes
   kept (the destructor one removes the dependence on thread timing).

## Acceptance Criteria

- **AC-1**: suite 23 (9 tests) passes; on the previous code all 9 FAIL (hang 124 x2, exit 0 x4,
  2048 wrong results x2, 10/12 summaries intact).
- **AC-2**: full suite passes.

## Not done

- Docs list `OMNIPROBE_*` variable names, the code reads `LOGDUR_*` (pre-existing doc
  inaccuracy, untouched).

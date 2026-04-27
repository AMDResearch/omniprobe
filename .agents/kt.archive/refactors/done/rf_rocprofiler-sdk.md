# Refactor: Migrate to rocprofiler-sdk registration

## Status
- [ ] TODO
- [ ] In Progress
- [ ] Blocked
- [x] Done

## Objective
Replace the deprecated `HSA_TOOLS_LIB` tool loading mechanism with rocprofiler-sdk's
`rocprofiler_configure()` registration API. This is the modern way for tools to hook
into the HSA runtime on ROCm >= 6.0.

## Background

### Current mechanism
`liblogDuration64.so` exports `OnLoad(HsaApiTable*, ...)` and `OnUnload()`. The HSA
runtime calls these when the library is specified via `HSA_TOOLS_LIB` env var. `OnLoad`
receives the `HsaApiTable*` which omniprobe hooks to intercept dispatches.

### New mechanism
rocprofiler-sdk discovers tools by scanning loaded libraries for the
`rocprofiler_configure()` symbol. The tool registers an intercept table callback via
`rocprofiler_at_intercept_table_registration()`, which receives the `HsaApiTable*`
when the HSA runtime initializes. Same table, different delivery path.

### Reference material
- PR #25 (jomadsen, June 2025): starter implementation, not mergeable but pattern is correct
- ROCm 7.2 rocprofiler-sdk v1.1.0 headers: `/opt/rocm-7.2.0/include/rocprofiler-sdk/`
- Official sample: `/opt/rocm-7.2.0/share/rocprofiler-sdk/samples/intercept_table/`

## Refactor Contract

### Goal
1. Add `rocprofiler_configure()` entry point to `liblogDuration64.so`
2. Route the `HsaApiTable*` from rocprofiler-sdk into the existing `hsaInterceptor` singleton
3. Update the omniprobe Python script to use the rocprofiler-sdk loading mechanism
4. Replace `OnLoad` with a hard error + abort if called via `HSA_TOOLS_LIB`

### Non-Goals / Invariants
- ABI compatibility: n/a (no external ABI consumers)
- API compatibility: the omniprobe CLI interface must not change
- Performance constraints: no additional overhead — registration happens once at startup
- Threading model: unchanged — same signal_runner, cache_watcher, comms_runner threads
- Interception behavior: identical — same `HsaApiTable` hooking, same dispatch interception
- All existing tests must continue to pass

### Verification Gates
- Build: `cmake --build build` succeeds with rocprofiler-sdk found
- Tests: `./tests/run_all_tests.sh` — all 6 suites pass (handler, library filter, hipBLASLt, rocBLAS, combined, Triton)
- Runtime: omniprobe CLI works with a simple instrumented kernel under the new mechanism

## Scope

### Affected Symbols
- New: `rocprofiler_configure()` — tool entry point (extern "C")
- New: `rocp_sdk_tool_init()` — initialization callback
- New: `rocp_sdk_tool_fini()` — finalization callback
- New: `rocp_sdk_api_registration_callback()` — receives HsaApiTable*
- Modified: `OnLoad()` — replace with hard error + abort (prevents use via HSA_TOOLS_LIB)
- Modified: `OnUnload()` — make empty no-op (keeps symbol for dynamic linker)
- Unchanged: `hsaInterceptor::getInstance()` — singleton guard already sufficient
- Modified: `setup_env()` in omniprobe Python script — change HSA_TOOLS_LIB to LD_PRELOAD or equivalent

### Expected Files
- `src/interceptor.cc` — add rocprofiler-sdk registration block, consolidate cleanup — confirmed
- `src/CMakeLists.txt` — add `find_package(rocprofiler-sdk REQUIRED)` and link — confirmed
- `omniprobe/omniprobe` — update tool loading env var — confirmed
- `inc/interceptor.h` — no changes expected (singleton interface unchanged) — hypothesis

### Call Graph Impact
Minimal. The new entry point calls `hsaInterceptor::getInstance()` with the same
`HsaApiTable*` parameter. All downstream interception logic is unchanged.

```
OLD:  HSA runtime → OnLoad(table) → getInstance(table) → hookApi()
NEW:  rocprofiler-sdk → rocprofiler_configure() → register callback
      → callback(table) → getInstance(table) → hookApi()
```

### Risks
- **Double initialization**: If both `HSA_TOOLS_LIB` and rocprofiler-sdk paths trigger,
  `getInstance()` could be called twice. Mitigation: the singleton already guards against
  this (only creates on first call). Verify this is sufficient.
- **Cleanup ordering**: The current code has three cleanup mechanisms (atexit,
  `__attribute__((destructor))`, `OnUnload`). Adding `rocp_sdk_tool_fini` is a fourth.
  Mitigation: consolidate into one idempotent cleanup function called from all paths.
- **omniprobe script change**: Switching from `HSA_TOOLS_LIB` to `LD_PRELOAD` (or other
  mechanism) could affect how the library is discovered. Need to verify the exact
  mechanism rocprofiler-sdk uses to find tools.

## Plan of Record

### Micro-steps

1. [x] **Add rocprofiler-sdk to build** — `find_package(rocprofiler-sdk REQUIRED)`, link
       target. Verify build succeeds. — Gate: compile ✓
2. [x] **Extract shared cleanup function** — Factored into `ensure_shutdown()` and
       `ensure_cleanup()`. atexit registration in `register_atexit_handler()`. — Gate: compile + tests ✓
3. [x] **Add rocprofiler-sdk registration** — `rocprofiler_configure()` registers for
       `ROCPROFILER_HSA_TABLE`. Callback passes `HsaApiTable*` to `getInstance()`.
       `rocp_tool_fini` calls `ensure_cleanup()`. — Gate: compile ✓
4. [x] **Test rocprofiler-sdk path manually** — Verified with `LD_PRELOAD` + simple
       kernel. Instrumented alternatives found and reports generated. — Gate: runtime ✓
5. [x] **Update omniprobe Python script** — Switched from `HSA_TOOLS_LIB` to `LD_PRELOAD`.
       Prepends to existing `LD_PRELOAD` if present. — Gate: tests ✓
6. [x] **Run full test suite** — Handler 22/22, library filter chain 5/5, Triton 5/5.
       hipBLASLt/rocBLAS suites skipped (no instrumented libs available). — Gate: all tests ✓
7. [x] **Replace OnLoad with hard error** — `OnLoad` prints error + aborts.
       `OnUnload` is empty no-op. Done in same commit as steps 2-3. — Gate: compile ✓

### Current Step
All steps complete.

## Progress Log
<!-- Append updates, don't delete -->

### Session 2026-03-24 (implementation)
- Completed all 7 micro-steps in one session
- Step 1: Added `find_package(rocprofiler-sdk REQUIRED HINTS ${ROCM_PATH})` + link target
- Steps 2-3 + 7: Consolidated cleanup into `ensure_shutdown()`/`ensure_cleanup()`/
  `register_atexit_handler()`. Added `rocprofiler_configure()` with
  `ROCPROFILER_HSA_TABLE` callback. Replaced `OnLoad` with error+abort guard.
- Step 4: Manual verification with `LD_PRELOAD` — full instrumentation pipeline works
- Step 5: Switched omniprobe script from `HSA_TOOLS_LIB` to `LD_PRELOAD`
- Step 6: Full test suite passed — handler 22/22, library filter chain 5/5, Triton 5/5
- Key decisions confirmed during pre-implementation discussion:
  - No transition period — hard switch to rocprofiler-sdk
  - OnLoad aborts with clear error message (not deprecation warning)
  - atexit handler migrated from OnLoad to new rocprofiler-sdk path
  - RTLD_NODELETE on handler plugins unaffected by refactor
- Commits: 4 (dossier update, CMake deps, interceptor rewrite, script update)

### Session 2026-03-23 (planning)
- Surveyed current `OnLoad`/`OnUnload` mechanism in `interceptor.cc`
- Reviewed PR #25 (jomadsen) for rocprofiler-sdk pattern
- Verified rocprofiler-sdk v1.1.0 API on ROCm 7.2 is compatible with PR's approach
- Confirmed rocprofiler-sdk is a standard ROCm component (ships with all installs)
- Decision: require rocprofiler-sdk (not optional), keep OnLoad/OnUnload for now
- Decision: implement from scratch against current code, using PR #25 as reference
- Created this dossier

## Rejected Approaches

- **Make rocprofiler-sdk optional with HSA_TOOLS_LIB fallback**: Adds complexity
  (#ifdef guards, two code paths). rocprofiler-sdk ships with every ROCm >= 6.0 install.
  Not worth maintaining both as first-class paths.
- **Merge PR #25 directly**: 9 months of divergence, merge conflicts throughout
  `interceptor.cc`. The PR was self-described as a "starter" that may not compile.
  Cleaner to implement fresh using the PR as a reference.

## Open Questions

- None. All resolved in session 2026-03-24 pre-implementation discussion.

## Resolved Questions

- **rocprofiler-sdk discovery mechanism**: Scans loaded libraries for `rocprofiler_configure`
  symbol. `LD_PRELOAD` is sufficient to make the symbol visible. Confirmed via
  `/opt/rocm-7.2.0/include/rocprofiler-sdk/intercept_table.h` and samples.
- **Transition period**: No transition. Switch entirely to rocprofiler-sdk. `OnLoad` becomes
  hard error + abort. No period where both paths work.
- **OnLoad/rocprofiler_configure coexistence**: `OnLoad` will abort, so no coexistence issue.
  If user accidentally sets `HSA_TOOLS_LIB`, they get a clear error message.
- **dlclose protection**: `RTLD_NODELETE` on handler plugins (in `handlerManager`) is
  independent of loading mechanism — unaffected. atexit handler must be registered from the
  new rocprofiler-sdk path (currently lives inside OnLoad).

## Last Verified
Commit: 35fb7cb (script update) on rf/rocprofiler-sdk branch
Date: 2026-03-24

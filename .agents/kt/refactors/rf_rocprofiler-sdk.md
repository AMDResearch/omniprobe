# Refactor: Migrate to rocprofiler-sdk registration

## Status
- [x] TODO
- [ ] In Progress
- [ ] Blocked
- [ ] Done

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
4. Keep `OnLoad`/`OnUnload` functional for backward compatibility (can be removed later)

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
- Modified: `OnLoad()` — add deprecation warning (or make internal)
- Modified: `OnUnload()` — consolidate cleanup with `rocp_sdk_tool_fini()`
- Modified: `hsaInterceptor::getInstance()` — guard against double init from both paths
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

1. [ ] **Add rocprofiler-sdk to build** — `find_package(rocprofiler-sdk REQUIRED)`, link
       target. Verify build succeeds. — Gate: compile
2. [ ] **Extract shared cleanup function** — Factor the atexit/shutdown/wait-for-signals
       logic out of `OnLoad`/`OnUnload`/`process_exit_cleanup` into a single idempotent
       function (e.g., `ensure_cleanup()`). All existing paths call it. — Gate: compile + tests
3. [ ] **Add rocprofiler-sdk registration** — Implement `rocprofiler_configure()`,
       `rocp_sdk_tool_init/fini()`, and `rocp_sdk_api_registration_callback()` in
       `interceptor.cc`. The callback calls `getInstance(table)`. `tool_fini` calls
       `ensure_cleanup()`. — Gate: compile
4. [ ] **Test rocprofiler-sdk path manually** — Run a simple instrumented kernel with
       `LD_PRELOAD=liblogDuration64.so` (without `HSA_TOOLS_LIB`) to verify the
       rocprofiler-sdk path works. — Gate: runtime verification
5. [ ] **Update omniprobe Python script** — Change `setup_env()` to use the rocprofiler-sdk
       loading mechanism instead of (or in addition to) `HSA_TOOLS_LIB`. — Gate: tests
6. [ ] **Run full test suite** — All 6 suites pass under the new mechanism. — Gate: all tests
7. [ ] **Add deprecation warning to OnLoad** (optional) — If `OnLoad` is called via
       `HSA_TOOLS_LIB`, print a warning suggesting the new mechanism. — Gate: compile

### Current Step
Not started.

## Progress Log
<!-- Append updates, don't delete -->

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

- What is the exact mechanism for rocprofiler-sdk tool discovery? Is `LD_PRELOAD`
  sufficient, or does the library need to be registered somewhere? Need to check the
  rocprofiler-sdk documentation and sample code.
- Should the omniprobe script set `HSA_TOOLS_LIB` AND `LD_PRELOAD` during a transition
  period, or switch entirely?
- Can `rocprofiler_configure()` and `OnLoad()` coexist safely if both are exported?
  The singleton guards against double init, but verify no other side effects.

## Last Verified
Commit: N/A
Date: 2026-03-23

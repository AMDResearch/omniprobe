# Refactor: Rename logDuration → omniprobe

## Status
- [x] TODO
- [ ] In Progress
- [ ] Blocked
- [ ] Done

## Objective
Purge all remnants of the historical "logDuration" / "logduration" / "LOGDUR" naming from the
codebase and replace them with "omniprobe"-based equivalents. The shared library becomes
`libomniprobe.so`, environment variables become `OMNIPROBE_*`, the C++ class and config
function are renamed, and all documentation/scripts/containers are updated to match.

## Refactor Contract

### Goal
Replace every user-visible and code-internal occurrence of the old name with an
omniprobe-flavored equivalent, producing a single, consistent identity for the project.

### Naming Mapping

| Old | New | Notes |
|-----|-----|-------|
| `liblogDuration64.so` | `libomniprobe.so` | Drop the `64` suffix (historical artifact) |
| `logDuration64` (CMake target) | `omniprobe_interceptor` | Clearer intent than bare "omniprobe" which is also the Python script |
| `logDuration` (CMake project name) | `omniprobe` | Top-level project() name |
| `LOGDUR_INSTRUMENTED` | `OMNIPROBE_INSTRUMENTED` | Env var |
| `LOGDUR_HANDLERS` | `OMNIPROBE_HANDLERS` | Env var |
| `LOGDUR_LOG_FORMAT` | `OMNIPROBE_LOG_FORMAT` | Env var |
| `LOGDUR_LOG_LOCATION` | `OMNIPROBE_LOG_LOCATION` | Env var |
| `LOGDUR_KERNEL_CACHE` | `OMNIPROBE_KERNEL_CACHE` | Env var |
| `LOGDUR_FILTER` | `OMNIPROBE_FILTER` | Env var |
| `LOGDUR_DISPATCHES` | `OMNIPROBE_DISPATCHES` | Env var |
| `LOGDUR_LIBRARY_FILTER` | `OMNIPROBE_LIBRARY_FILTER` | Env var |
| `class logDuration` | `class durationLogger` | Descriptive name for what it actually does |
| `getLogDurConfig()` | `getOmniprobeConfig()` | Free function in utils |
| `logDuration log_` member | `durationLogger log_` | In `hsaInterceptor` |
| Local vars `logDurLogFormat`, `logDurLogLocation`, etc. | `opLogFormat`, `opLogLocation`, etc. | In handler .cc files |

### Non-Goals / Invariants
- **ABI compatibility**: n/a — no stable ABI promise exists
- **API compatibility**: n/a — no external consumers of the C++ API
- **Behavioral changes**: None — this is a pure rename, no logic changes
- **Submodule code**: Do NOT modify code inside `external/dh_comms/` or `external/kerneldb/` (separate repos). Exception: `external/dh_comms/examples/CMakeLists.txt` references `logDuration64` as a link target — this must be updated to match.
- **KT documents**: Update `.agents/kt/` dossiers as a final step (non-blocking)
- **install/ directory**: This is a build artifact (gitignored?). Skip it; it will be regenerated.

### Verification Gates
- **Build**: `cmake --build build` succeeds (no unresolved symbols, correct .so name)
- **Tests**: `tests/run_handler_tests.sh` — all handler tests pass
- **Tests**: `tests/run_triton_tests.sh` — all Triton integration tests pass (if Triton is configured)
- **Runtime**: `omniprobe -i -a MemoryAnalysis -- <test_binary>` runs successfully
- **Grep check**: `grep -ri logdur . --include='*.cc' --include='*.h' --include='*.py' --include='*.txt' --include='*.cmake' --include='*.sh' --include='*.yml' --include='*.Dockerfile' --include='*.def'` returns zero hits (excluding `.agents/kt/refactors/done/` archives and `README.md` historical mentions)

## Scope

### Affected Symbols
- `class logDuration` → `class durationLogger` — `inc/utils.h:212`
- `logDuration::logDuration()` etc. → `durationLogger::...` — `src/utils.cc:807-858`
- `logDuration log_` → `durationLogger log_` — `inc/interceptor.h:166`
- `getLogDurConfig()` → `getOmniprobeConfig()` — `inc/utils.h:260`, `src/utils.cc:766`
- All `LOGDUR_*` string literals in env var reads/writes
- `INTERCEPTOR_NAME`, `INTERCEPTOR_TARGET`, `INTERCEPTOR_LIBRARY` CMake variables

### Expected Files

**C++ source / headers** (confirmed):
- `inc/utils.h` — class rename, function rename
- `inc/interceptor.h` — member type rename
- `src/utils.cc` — class impl rename, function rename, env var string literals
- `src/interceptor.cc` — env var string refs, `getLogDurConfig()` call
- `src/memory_analysis_handler.cc` — local var names, env var reads
- `src/memory_heatmap.cc` — local var name, env var read
- `src/basic_block_analysis.cc` — local var name, env var read
- `src/time_interval_handler.cc` — local var names, env var reads
- `src/message_logger.cc` — local var name, env var read
- `src/comms_mgr.cc` — `LOGDUR_HANDLERS` config key lookup
- `plugins/plugin.cc` — local var name, env var read
- `plugins/logger_plugin.cc` — same
- `plugins/memory_analysis_plugin.cc` — same
- `plugins/basic_block_plugin.cc` — same

**CMake files** (confirmed):
- `CMakeLists.txt` — project name, target name, library name, install target
- `src/CMakeLists.txt` — link target `logDuration64` (×2)
- `plugins/CMakeLists.txt` — link target `logDuration64` (×2)
- `tests/CMakeLists.txt` — commented-out `logDuration64` ref
- `external/dh_comms/examples/CMakeLists.txt` — link target `logDuration64`

**Python / scripts** (confirmed):
- `omniprobe/omniprobe` — `liblogDuration64.so` literal, all `LOGDUR_*` env var names

**Containers** (partially done via rf_container-local):
- `containers/omniprobe.def` — ~~install path `/opt/logduration`, PATH refs~~ (fixed); still has `liblogDuration64.so` ref
- `containers/omniprobe.Dockerfile` — ~~same~~ (fixed); still has `liblogDuration64.so` ref

**CI** (confirmed):
- `.github/workflows/build.yml` — install path `/opt/logduration`

**Documentation** (confirmed):
- `README.md` — multiple references (some historical narrative, some functional)

**Test scripts** (confirmed):
- `src/test/st.sh` — old hardcoded path in comment (can clean up or remove)

### Call Graph Impact
No runtime behavior changes. All renames are mechanical. The `getOmniprobeConfig()` function
is called from `hsaInterceptor` constructor and one other location in `utils.cc` — both are
simple renames of the call site.

### Risks
- **Submodule breakage**: `external/dh_comms/examples/CMakeLists.txt` links against
  `logDuration64`. This is inside a git submodule — changing it requires a commit to the
  dh_comms repo and updating the submodule pointer. **Mitigation**: Handle dh_comms as a
  separate step; consider whether that example is even built/used.
- **User environments**: Anyone with scripts referencing `LOGDUR_*` env vars or
  `liblogDuration64.so` will break. **Mitigation**: This is an internal tool with a small user
  base; announce the change. Optionally, add a one-time fallback that reads old env vars and
  warns — but this is a non-goal for a clean break.
- **Container image cache**: Existing container images reference `/opt/logduration`. Rebuild
  will fix. **Mitigation**: None needed; containers are rebuilt from scratch.
- **`install/` directory**: Contains a copy of the omniprobe script with old names. Appears to
  be a build artifact checked in or left behind. Verify whether it's gitignored; if tracked,
  update or remove.

## Plan of Record

### Micro-steps

1. [ ] **Rename CMake targets and project** — Gate: build
   - `CMakeLists.txt`: Change `INTERCEPTOR_NAME` to `"omniprobe"`, `INTERCEPTOR_TARGET` to
     `"omniprobe_interceptor"`, update project() description and URL
   - `src/CMakeLists.txt`: Update link targets
   - `plugins/CMakeLists.txt`: Update link targets
   - `tests/CMakeLists.txt`: Update commented reference
   - Build must produce `libomniprobe_interceptor.so` (or chosen name)

2. [ ] **Rename C++ class and config function** — Gate: build
   - `inc/utils.h`: `class logDuration` → `class durationLogger`
   - `src/utils.cc`: All `logDuration::` method implementations → `durationLogger::`
   - `inc/interceptor.h`: Member `logDuration log_` → `durationLogger log_`
   - `inc/utils.h`: `getLogDurConfig()` → `getOmniprobeConfig()`
   - `src/utils.cc`: Function definition rename
   - `src/interceptor.cc`: Call site rename

3. [ ] **Rename environment variable strings** — Gate: build + runtime test
   - `src/utils.cc` (`getOmniprobeConfig()`): All `LOGDUR_*` → `OMNIPROBE_*` in string
     literals and error messages
   - `src/interceptor.cc`: All `LOGDUR_*` config key lookups
   - `src/comms_mgr.cc`: `LOGDUR_HANDLERS` → `OMNIPROBE_HANDLERS`
   - `src/memory_analysis_handler.cc`: `LOGDUR_LOG_FORMAT`, `LOGDUR_FILTER`
   - `src/memory_heatmap.cc`: `LOGDUR_LOG_FORMAT`
   - `src/basic_block_analysis.cc`: `LOGDUR_LOG_FORMAT`
   - `src/time_interval_handler.cc`: `LOGDUR_LOG_FORMAT`
   - `src/message_logger.cc`: `LOGDUR_LOG_FORMAT`
   - `plugins/*.cc` (4 files): `LOGDUR_LOG_LOCATION`
   - Rename local variables (`logDurLogFormat` → `opLogFormat`, etc.) for consistency
   - `src/utils.cc` dispatch count function: `LOGDUR_DISPATCHES` → `OMNIPROBE_DISPATCHES`

4. [ ] **Update Python omniprobe script** — Gate: runtime test
   - `omniprobe/omniprobe`: Change `liblogDuration64.so` to `libomniprobe_interceptor.so`
     (must match CMake output name)
   - `omniprobe/omniprobe`: All `LOGDUR_*` env var names → `OMNIPROBE_*`

5. [~] **Update containers and CI** — Gate: CI build (or manual container build)
   - ~~`containers/omniprobe.def`: `/opt/logduration` → `/opt/omniprobe`, PATH fixes~~ (done in rf_container-local)
   - ~~`containers/omniprobe.Dockerfile`: Same changes~~ (done in rf_container-local)
   - `.github/workflows/build.yml`: `/opt/logduration` → `/opt/omniprobe`
   - Remaining: update `liblogDuration64.so` references to new library name (depends on step 1 decision)

6. [ ] **Update README and documentation** — Gate: none (docs only)
   - `README.md`: Update functional references; keep historical paragraph about the name origin
   - `src/test/st.sh`: Clean up or remove stale commented-out command

7. [ ] **Handle dh_comms submodule reference** — Gate: build with dh_comms examples
   - `external/dh_comms/examples/CMakeLists.txt`: `logDuration64` → `omniprobe_interceptor`
   - This requires a commit to the dh_comms repo + submodule pointer update
   - Alternatively, assess whether this example is actively used; if not, defer

8. [ ] **Verify `install/` directory status** — Gate: clean grep check
   - Check if `install/` is gitignored or tracked
   - If tracked: update or remove (it's a build artifact)
   - If gitignored: skip (will be regenerated)

9. [ ] **Update KT dossiers** — Gate: none
   - Update `.agents/kt/architecture.md`, `interceptor.md`, `omniprobe_cli.md`,
     `comms_mgr.md`, `plugins.md`, `glossary.md`, `memory_analysis.md`
   - Update `sub_instrument_amdgpu.md`
   - Do NOT update `refactors/done/` — those are historical records

10. [ ] **Final grep audit** — Gate: zero remaining hits
    - Run comprehensive grep for `logdur`, `logDur`, `LOGDUR`, `logDuration`, `logduration`
      across all active source, scripts, cmake, yml, Dockerfile, def files
    - Exclude: `.agents/kt/refactors/done/`, `README.md` (historical paragraph only)
    - Fix any stragglers

### Current Step
Not started — dossier is in TODO status.

## Design Decisions

### Library name: `libomniprobe_interceptor.so` vs `libomniprobe.so`
The `omniprobe` name is already used by the Python CLI script. Using `libomniprobe.so` for the
shared library could cause confusion. `libomniprobe_interceptor.so` is more descriptive.
**Decision**: To be confirmed with user during step 1.

### Drop the `64` suffix?
The `64` in `logDuration64` is a historical artifact (64-bit only). Modern builds are always
64-bit. **Recommendation**: Drop it. **Decision**: To be confirmed with user.

### Environment variable prefix: `OMNIPROBE_` vs `OP_`
`OMNIPROBE_` is explicit and self-documenting. `OP_` is shorter but cryptic.
**Recommendation**: Use `OMNIPROBE_`. **Decision**: To be confirmed with user.

### Backward-compatible env var fallback?
Could add code that checks `LOGDUR_*` if `OMNIPROBE_*` is not set, and prints a deprecation
warning. **Recommendation**: Skip — small user base, clean break is simpler.
**Decision**: To be confirmed with user.

## Open Questions
1. Confirm library target name: `omniprobe_interceptor` vs something else?
2. Confirm dropping the `64` suffix — any reason to keep it?
3. Confirm `OMNIPROBE_` as env var prefix.
4. Should we add backward-compatible `LOGDUR_*` fallback with deprecation warning, or clean break?
5. Is `install/` tracked in git or gitignored?
6. Is the `dh_comms/examples/CMakeLists.txt` example actively built? If not, can defer.

## Rejected Approaches
(None yet — refactor not started)

## Progress Log
<!-- Append updates, don't delete -->

### Session 2026-04-07
- Created refactor dossier after comprehensive codebase survey
- Identified all occurrences across 30+ files in 8 categories
- Drafted 10-step micro-plan with verification gates
- Status: TODO (awaiting user review of dossier and open questions)

## Last Verified
Commit: N/A
Date: 2026-04-07

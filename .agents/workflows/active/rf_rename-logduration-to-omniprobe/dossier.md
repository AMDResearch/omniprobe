# Workflow Dossier: rf_rename-logduration-to-omniprobe

## Metadata
- **Type**: refactor
- **State**: active
- **Owner**: unassigned
- **Created**: 2026-04-07 (migrated from KT)
- **Write Scope**: `src/`, `inc/`, `plugins/`, `omniprobe/omniprobe`, `CMakeLists.txt`, `src/CMakeLists.txt`, `plugins/CMakeLists.txt`, `tests/CMakeLists.txt`, `containers/`, `.github/workflows/build.yml`, `README.md`, `external/dh_comms/examples/CMakeLists.txt`
- **Dependencies**: None
- **Failure Policy**: stop

## Objective
Purge all remnants of the historical "logDuration" / "LOGDUR" naming from the codebase and replace with "omniprobe"-based equivalents. Library becomes libomniprobe_interceptor.so, environment variables become OMNIPROBE_*, classes and config functions renamed.

## Non-Goals / Invariants
- ABI compatibility: n/a — no stable ABI
- API compatibility: n/a — no external consumers
- No behavioral changes — pure rename
- Do NOT modify code inside external/dh_comms/ or external/kerneldb/ (separate repos), except dh_comms examples/CMakeLists.txt

## Acceptance Criteria
1. Build: cmake --build build succeeds
2. Tests: all handler + Triton tests pass
3. Runtime: omniprobe -i -a MemoryAnalysis runs successfully
4. Grep check: zero hits for logdur/logDur/LOGDUR in active source (excluding archives and historical README mentions)

## Plan of Record
1. Rename CMake targets and project
2. Rename C++ class and config function (logDuration -> durationLogger, getLogDurConfig -> getOmniprobeConfig)
3. Rename environment variable strings (LOGDUR_* -> OMNIPROBE_*)
4. Update Python omniprobe script
5. Update containers and CI
6. Update README and documentation
7. Handle dh_comms submodule reference
8. Verify install/ directory status
9. Update PM
10. Final grep audit

## Open Questions
1. Confirm library target name: omniprobe_interceptor vs something else?
2. Confirm dropping the 64 suffix
3. Confirm OMNIPROBE_ as env var prefix
4. Should we add backward-compatible LOGDUR_* fallback with deprecation warning?
5. Is install/ tracked in git or gitignored?
6. Is dh_comms/examples/CMakeLists.txt actively built?

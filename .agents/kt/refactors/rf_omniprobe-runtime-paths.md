# Refactor: Omniprobe Runtime Path Resolution

## Status
- [ ] TODO
- [x] In Progress
- [ ] Blocked
- [ ] Done

## Objective

Ensure the `omniprobe` Python script correctly resolves handler libraries and
other runtime artifacts when run from either the **build tree** or the
**install tree**. Currently, named analyzers (`-a Heatmap`) fail with `dlopen`
errors unless `LD_LIBRARY_PATH` is manually set.

## Problem Statement

The `omniprobe` script (`omniprobe/omniprobe`) supports two runtime modes:

1. **Build mode**: running from the source tree against `build/` artifacts
2. **Install mode**: running from a `cmake --install` destination

The mode is determined at lines 220-223 by comparing the install dir's
`bin/logDuration` symlink against the script's own directory.

### Current behavior (build mode)

- `install_path = ("build", build_dir)` where `build_dir` comes from
  `build/runtime_config.txt`
- **Default handlers** (no `-a`): line 556 constructs an absolute path like
  `{build_dir}/libdefaultMessageHandlers64.so` — this works.
- **Named analyzers** (`-a Heatmap`): line 779 appends bare `lib_name` from
  `omniprobe/config/analytics.py` (e.g., `libdefaultMessageHandlers64.so`).
  This bare name goes into `LOGDUR_HANDLERS` env var. The C++ code does
  `dlopen("libdefaultMessageHandlers64.so", ...)` which fails without
  `LD_LIBRARY_PATH`.
- **`LD_LIBRARY_PATH`**: lines 434-438 set it to `get_omniprobe_home()/lib`
  which resolves to `omniprobe/lib` — a directory that doesn't exist.
  Should include `build_dir` instead.
- **`HSA_TOOLS_LIB`**: set via `op_run_env` from config files. Need to verify
  this resolves correctly in build mode.

### Current behavior (install mode)

- `install_path = ("install", install_dir)` where `install_dir` comes from
  `build/runtime_config.txt`
- Default handlers use `{install_dir}/lib/libdefaultMessageHandlers64.so`
- `LD_LIBRARY_PATH` set to `get_omniprobe_home()/lib` — need to verify
  `get_omniprobe_home()` returns the install dir in this case
- **Not tested recently** — need to verify install mode works end-to-end

## Source Material

- `omniprobe/omniprobe` — main script
  - Lines 190-223: `get_install_path()` — mode detection
  - Lines 236-238: `get_omniprobe_home()` — returns script's own directory
  - Lines 434-438: `LD_LIBRARY_PATH` setup
  - Lines 520-542: `load_config_files()` — analytics config loading
  - Line 556: default handler path construction
  - Lines 774-784: named analyzer → handler lib resolution
- `omniprobe/config/analytics.py` — analyzer name → bare lib_name mapping
- `omniprobe/config/triton_config.py` — Triton-specific config
- `CMakeLists.txt` — install rules, `runtime_config.txt` generation
- `build/runtime_config.txt` — runtime paths written at cmake configure time

## Investigation Plan

### Phase 1: Understand current path resolution

- [ ] Trace all environment variables set by `omniprobe` for a HIP run
      (`omniprobe --dump-env -i -a MemoryAnalysis -- some_kernel`)
- [ ] Trace all environment variables for a Triton run
- [ ] Map which paths are absolute vs relative vs bare names
- [ ] Check `get_omniprobe_home()` return value in both build and install mode
- [ ] Check what `cmake --install` actually installs and where

### Phase 2: Test install mode

- [ ] Run `cmake --install build --prefix /tmp/omniprobe-install` (or similar)
- [ ] Verify directory structure: where do `.so` files, config files, and the
      `omniprobe` script end up?
- [ ] Run omniprobe from the install tree with `-a MemoryAnalysis`
- [ ] Run omniprobe from the install tree with a Triton program

### Phase 3: Fix path resolution

Based on findings from Phases 1-2, fix the path resolution. Likely changes:

- **`LD_LIBRARY_PATH`**: In build mode, prepend `build_dir`. In install mode,
  prepend `install_dir/lib`. The `get_omniprobe_home()/lib` fallback is wrong
  for build mode.
- **Named analyzer resolution** (line 779): Prepend the appropriate lib
  directory to bare `lib_name` values, so `LOGDUR_HANDLERS` contains absolute
  paths (same as the default handler path on line 556).
- **Or**: Keep bare names but ensure `LD_LIBRARY_PATH` is always correct, so
  `dlopen` finds them. This is simpler but relies on `LD_LIBRARY_PATH`.

### Phase 4: Test both modes

- [ ] Run handler tests from build tree (19 tests)
- [ ] Run Triton integration tests from build tree (5 tests)
- [ ] Run handler tests from install tree
- [ ] Run Triton integration tests from install tree

## Files to Modify

- `omniprobe/omniprobe` — path resolution fixes
- Possibly `omniprobe/config/analytics.py` — if lib_name needs full paths
- Possibly `CMakeLists.txt` — if install rules need adjustment

## Risk Assessment

- **Low risk**: Changes are isolated to the `omniprobe` Python script's
  environment setup. No C++ code changes needed.
- **Testing**: Existing test suite covers both HIP and Triton paths.
  Need to add install-mode testing.

### Current Step

Phase 1 (not started — will begin in a future session)

## Progress Log

### 2026-03-18: Dossier created
- Issue discovered during triton-install-script refactor testing
  (see `rf_triton-install-script.md`, Session 2026-03-18b)
- Root cause identified: bare `lib_name` in analytics config + wrong
  `LD_LIBRARY_PATH` in build mode
- Handler tests pass with manual `LD_LIBRARY_PATH` workaround

## Last Verified
Date: 2026-03-18

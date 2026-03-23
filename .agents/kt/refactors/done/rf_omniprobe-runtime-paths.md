# Refactor: Omniprobe Runtime Path Resolution

## Status
- [ ] TODO
- [ ] In Progress
- [ ] Blocked
- [x] Done

## Objective

Ensure the `omniprobe` Python script correctly resolves handler libraries and
other runtime artifacts when run from either the **build tree** or the
**install tree**. Previously, named analyzers (`-a Heatmap`) failed with `dlopen`
errors unless `LD_LIBRARY_PATH` was manually set.

## Changes Made

### Root causes found

1. **`LD_LIBRARY_PATH`** (lines 462-467): Was set to `get_omniprobe_home()/lib`
   = `omniprobe/lib` — a non-existent directory.
2. **Named analyzer handler paths** (line 807): Returned bare `lib_name`
   (e.g. `libMemAnalysis64.so`) instead of absolute paths.

### Fix

Introduced `handler_lib_dir` variable computed at module level (alongside
`base_llvm_pass_plugin` and `base_hsa_tools_lib`):
- **Build mode**: `handler_lib_dir = build_dir` (where all `.so` files live)
- **Install mode**: `handler_lib_dir = install_dir/lib` (handler `.so` files
  install to `lib/`, not `lib/logDuration/` which only has the interceptor)

Used `handler_lib_dir` in two places:
1. `LD_LIBRARY_PATH` setup (line 464): prepends `handler_lib_dir` instead of
   the bogus `get_omniprobe_home()/lib`
2. Named analyzer resolution (line 809): `os.path.join(handler_lib_dir, lib_name)`
   produces absolute paths, consistent with default handler behavior

### Install layout (reference)

```
<prefix>/
  bin/logDuration/
    omniprobe          (script)
    config/            (analytics.py etc.)
    runtime_config.txt
  lib/
    libdefaultMessageHandlers64.so   ← handler libs here
    libMemAnalysis64.so
    libLogMessages64.so
    libBasicBlocks64.so
    libdh_comms.so
    libkernelDB64.so
  lib/logDuration/
    liblogDuration64.so              ← interceptor here
```

## Files Modified

- `omniprobe/omniprobe` — 3 hunks: handler_lib_dir definition, LD_LIBRARY_PATH
  setup, named analyzer resolution

## Known Limitations (not in scope)

- **`runtime_config.txt` is baked at cmake configure time**: `install_dir` is
  the value from `CMAKE_INSTALL_PREFIX`, not the actual `--prefix` used at
  `cmake --install` time. Install mode only works when the actual install
  location matches the configured prefix.
- **Relocatable installs**: The script should derive paths from its own location
  rather than from `runtime_config.txt` for full relocatability.

## Verification

- Handler tests: 22/22 passing (build mode)
- Triton integration: 5/5 passing (build mode)
- Install mode env dump: correct absolute paths for HSA_TOOLS_LIB,
  LOGDUR_HANDLERS, and LD_LIBRARY_PATH

## Progress Log

### 2026-03-18: Dossier created
- Issue discovered during triton-install-script refactor testing
- Root cause identified: bare `lib_name` in analytics config + wrong
  `LD_LIBRARY_PATH` in build mode
- Handler tests pass with manual `LD_LIBRARY_PATH` workaround

### 2026-03-23: Fix implemented and verified
- Completed Phase 1 (traced all path resolution)
- Completed Phase 3 (fix: handler_lib_dir, LD_LIBRARY_PATH, named analyzers)
- Completed Phase 4 (build mode: 22+5 tests pass; install mode: env dump verified)
- Discovered install layout: handlers at lib/, interceptor at lib/logDuration/
- Noted pre-existing limitation: runtime_config.txt baked at configure time

## Last Verified
Commit: 8645772
Date: 2026-03-23

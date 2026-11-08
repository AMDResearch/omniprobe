# Dossier — bf_kernel-filter-search

## Metadata

- Workflow ID: bf_kernel-filter-search
- Workflow Type: bugfix
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Base Commit: 50837b8

```write-scope
src/interceptor.cc
inc/interceptor.h
tests/test_kernels/kernel_filter_names_test.cpp
tests/test_kernels/CMakeLists.txt
tests/test_kernel_filter_names.sh
tests/run_all_tests.sh
docs/usage.md
```

## Report (pnimpl via supervisor, 2026-11-08)

At 13ca707, `-k gpuMain` / API `kernel_filter="gpuMain"` no longer matched PENNANT's `gpuMain2`,
`gpuMain3_interior`, ...; IntelliKit said "no instrumented kernels"; `".*gpuMain.*"` worked.

## Findings (measured, PENNANT sedovsmall built with the AddressMessages plugin, gfx90a)

- **Not reproduced.** HEAD (50837b8) and a separate build of 13ca707 (`/tmp` worktree), CLI and
  Python API: `gpuMain` and `.*gpuMain.*` select the same 40 dispatches of all four gpuMain
  kernels; `gpuMain2` -> 10, `Main3_int` -> 10. The match is `std::regex_search` on the demangled
  name (`src/interceptor.cc` runKernelInstrumented; `src/utils.cc` coCache::addFile), unchanged
  between 821ba07 and 13ca707.
- At 13ca707 **without ROCM_PATH** (no /opt/rocm here) both filters fail identically (kernelDB
  "Command failed" x40, dispatches dropped — fixed in 50837b8). IntelliKit's "no instrumented
  kernels" is its generic message for an empty result (intellikit omniprobe/api.py
  `_no_data_message`). [inf] pnimpl's two runs probably differed in environment, not filter.
- Real pitfall found: `^gpuMain` misses the template kernels (`void gpuMain2<4>(...)`).

## Changes

- Exit warning when a `-k` filter matched none of the dispatched instrumented kernels, listing
  them — distinct from "kernel(s) ran uninstrumented because no instrumented clone was found".
- Suite 24 pins the semantics: substring/prefix, anchored, alternation, template with and
  without the return type, static `.intern`, no-parameter, anonymous-namespace kernels.
- docs/usage.md: "searched in the demangled name", demangled-name examples, anchoring pitfall.

## Acceptance Criteria

- **AC-1**: suite 24 10/10; on the previous interceptor 8/10 (the two no-match cases FAIL: no
  warning) — the search semantics already held.
- **AC-2**: full suite passes.

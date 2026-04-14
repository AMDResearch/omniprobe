# Refactor: Adopt Lazy kernelDB Loading

## Status
- [ ] TODO
- [x] Ready to Start
- [ ] In Progress
- [ ] Done

## Objective
Replace the current `scanCodeObject()` call in `interceptor.cc` with `addFile(path, agent, filter, lazy=true)` so that kernelDB only disassembles the specific kernels that are actually dispatched, rather than every kernel in the code object.

## Motivation

Omniprobe already defers kernelDB population to first dispatch (good), but when a kernel is
first dispatched, `scanCodeObject()` disassembles the **entire** code object. For large
libraries this is wasteful:

- hipBLASLt matrix transform `.hsaco`: 960 kernels — only a handful are dispatched per run
- rocBLAS: 300+ kernels per code object

With lazy loading, only the dispatched kernel is disassembled on demand. For a typical
profiling session that exercises 5-10 kernels from a 960-kernel code object, this eliminates
~99% of the disassembly work.

## Upstream Dependency: kerneldb PR #27 — MERGED

[kerneldb PR #27](https://github.com/AMDResearch/kerneldb/pull/27) was merged on 2026-04-14.
Omniprobe submodule updated to `995bc16`. All 6 review issues verified fixed:

1. **Thread safety** — Fixed via `loading_mutex_` + `loading_cv_` + `loading_kernels_` sentinel
2. **Temp file leak** — Fixed; `unlink()` on both success and failure paths
3. **Debug output** — Removed; no more `[KDB]` stderr prints
4. **Silent failure** — Fixed; `lazy_kernels_.erase()` on failure prevents infinite retries
5. **`tmpnam()` → `mkstemp()`** — Fixed in both `getDisassembly()` and `getDisassemblyForSymbol()`
6. **Test coverage** — `tests/test_lazy_loading.py` added (4 tests: discovery, has_kernel,
   assembly equivalence, instruction equivalence)

Omniprobe builds and all 30 tests pass (25 handler + 5 Triton) against the merged code.

## Refactor Contract

### Goal
Switch from `scanCodeObject()` (disassemble-everything) to `addFile(lazy=true)` +
`ensureKernelLoaded()` (disassemble-on-demand) for kernelDB population.

### Non-Goals / Invariants
- **No behavioral change in analysis output** — handlers must produce identical reports
- **No API changes in Omniprobe** — the `omniprobe` script and CLI are unaffected
- **No changes to coCache** — `coCache::addFile()` (symbol extraction, HSA loading) is
  unchanged; only the kernelDB population path changes

### Verification Gates
- **Build**: `cmake --build build` succeeds
- **Tests**: `tests/run_handler_tests.sh` — all 25 handler tests pass
- **Tests**: `tests/triton/run_test.sh` — all 5 Triton integration tests pass
- **Correctness**: Output of `omniprobe -i -a MemoryAnalysis -- <test_binary>` is identical
  before and after the change

## Scope

### Current Flow (interceptor.cc)

```
Startup (line 226-249):
  kdbs_[agent] = make_unique<kernelDB>(agent)     // empty kernelDB
  kernel_cache_.addFile(file, agent, strFilter)    // coCache extracts symbols
  // kernelDB scanning deferred to dispatch time

First dispatch (line 800-807):
  kdb = kdbs_[agent].get()
  if (!kdb->hasKernel(name))                       // not yet scanned?
      kdb->scanCodeObject(coRef.co_file)           // disassemble EVERYTHING

Handler invocation:
  kdb.getKernel(name)                              // already loaded
```

### Target Flow

```
Startup (line 226-249):
  kdbs_[agent] = make_unique<kernelDB>(agent)      // empty kernelDB
  kernel_cache_.addFile(file, agent, strFilter)     // coCache extracts symbols
  kdb->addFile(coRef.co_file, agent, filter, true)  // index ELF symbols only (lazy)

First dispatch (line 800-807):
  // Remove hasKernel + scanCodeObject block entirely.
  // kernelDB::getKernel() internally calls ensureKernelLoaded() which
  // disassembles just the one kernel on demand.

Handler invocation:
  kdb.getKernel(name)                               // triggers lazy load if needed
```

### Affected Files

- `src/interceptor.cc` — replace `scanCodeObject()` with `addFile(lazy=true)` at startup;
  remove the `hasKernel` / `scanCodeObject` block at dispatch time (lines 802-808)

### Timing Consideration

Currently, `scanCodeObject()` is called at dispatch time (line 807) while the dispatch is
being intercepted. Moving the `addFile(lazy=true)` call to startup (after `coCache::addFile`)
means the ELF symbol scan happens once during initialization rather than on-demand. This is
cheap (ELF symbol table scan, no disassembly) and eliminates a conditional check on every
dispatch.

The actual disassembly still happens at dispatch time — but now inside `getKernel()` via
`ensureKernelLoaded()`, and only for the specific kernel being dispatched.

### Complication: Code Object Path — RESOLVED

At startup (line 237), Omniprobe iterates over shared library files and calls
`kernel_cache_.addFile(file, agent, strFilter)`. The `file` here is the shared library path
(e.g., `/path/to/libhipblaslt.so`). However, `kernelDB::addFile()` expects a code object
path (e.g., an extracted `.hsaco` file).

**Investigation result (2026-04-14):** `kernelDB::addFile()` actually accepts both shared
library paths *and* `.hsaco` paths. For non-`.hsaco` files, it internally calls
`extractCodeObjects()` and stores results in `file_map_`. So we can pass the original
shared library path directly to `kdb->addFile(file, agent, strFilter, true)` — no need to
expose code object paths from coCache.

**However**, the simpler approach is **Option 2**: keep the dispatch-time location and just
remove the explicit `hasKernel` + `scanCodeObject` block. Since all handler query methods
(`getKernel`, `getInstructionsForLine`, `getFileName`, `getKernelLines`) now internally call
`ensureKernelLoaded()`, the lazy loading is triggered automatically on first use.

The cleanest implementation:
1. At startup: call `kdb->addFile(file, agent, strFilter, true)` right after
   `kernel_cache_.addFile(file, agent, strFilter)` (line 237). This indexes ELF symbols.
2. At dispatch time: remove the `hasKernel` / `scanCodeObject` block (lines 802-808).
3. Handlers call `getKernel()` etc. which triggers `ensureKernelLoaded()` automatically.

For the `addCodeObject()` runtime path (line 302): same pattern — call
`kdb->addFile(name, agent, filter, true)` after `kernel_cache_.addFile()`.

### Risks
- **Latency shift**: Disassembly cost moves from first-dispatch-of-any-kernel-in-CO to
  first-dispatch-of-each-kernel. If many distinct kernels are dispatched, the total wall time
  is higher (N separate `llvm-objdump --disassemble-symbols` invocations vs one full
  disassembly). For Omniprobe's typical use case (few kernels, large COs), this is a net win.
- **Error visibility**: ~~If `ensureKernelLoaded()` fails silently~~ — Fixed upstream.
  On failure, the entry is removed from `lazy_kernels_`, and `getKernel()` throws
  "kernel does not exist." This is acceptable — the error surfaces immediately.

## Plan of Record

### Micro-steps

1. [x] **Verify upstream prerequisites** — Gate: all checklist items pass
   - PR #27 merged, all 6 issues fixed, 30/30 Omniprobe tests pass (done 2026-04-14)

2. [x] **Survey coCache for code object path access** — Gate: none (research)
   - `kernelDB::addFile()` accepts both .so and .hsaco paths (extracts COs internally)
   - No coCache changes needed — pass original file path directly (done 2026-04-14)

3. [ ] **Add lazy addFile calls at startup** — Gate: build
   - After `kernel_cache_.addFile(file, agent, strFilter)` in startup loop (line 237),
     add: `kdbs_[agent]->addFile(file, agent, strFilter, true);`
   - Same for `addCodeObject()` path (line 302):
     add: `kdbs_[agent]->addFile(name, agent, config_["LOGDUR_FILTER"], true);`

4. [ ] **Remove scanCodeObject dispatch-time block** — Gate: build + tests
   - Remove lines 802-808 in `interceptor.cc` (the `hasKernel` / `scanCodeObject` block)
   - `getKernel()` in handlers will now trigger lazy loading automatically

5. [ ] **Run full test suite** — Gate: all tests pass
   - Handler tests: 25/25
   - Triton tests: 5/5
   - Compare output with pre-refactor baseline for identical results

6. [ ] **Performance validation** — Gate: qualitative (no regression for small kernel sets)
   - Run `omniprobe -i -a MemoryAnalysis` on a hipBLASLt workload
   - Verify startup is faster (no full CO disassembly)
   - Check that per-kernel dispatch latency is acceptable

7. [ ] **Update KT** — Gate: none
   - Update `architecture.md` to reflect lazy loading
   - Update this dossier status to Done

### Current Step
Ready to start at step 3. Upstream dependency resolved; design decision made.

## Design Decisions

1. **Pass original file path to `kdb->addFile()`** — `kernelDB::addFile()` accepts both
   `.so` and `.hsaco` paths (it runs `extractCodeObjects()` internally for non-`.hsaco`).
   No need to expose code object paths from coCache.

2. **No fallback to `scanCodeObject()`** — If lazy loading fails for a kernel, the error
   should surface immediately. `ensureKernelLoaded()` removes the entry from `lazy_kernels_`
   on failure, so `getKernel()` throws "kernel does not exist" — clear and actionable.

## Rejected Approaches

1. **Expose code object paths from coCache** (option 1 from original analysis) — Unnecessary
   since `kernelDB::addFile()` handles code object extraction internally.
2. **Dispatch-time-only `addFile(lazy=true)`** (option 2) — Works but adds a per-dispatch
   conditional. Better to call at startup for a cleaner control flow.

## Progress Log

### Session 2026-04-14
- Verified all 6 review issues fixed in PR #27 (thread safety, temp file leak, debug
  output, silent failure, tmpnam→mkstemp, test coverage)
- Built Omniprobe against PR branch; all 30 tests pass (25 handler + 5 Triton)
- Merged PR #27 into kerneldb main (`995bc16`)
- Updated Omniprobe submodule pointer, committed (`c424906`)
- Surveyed coCache: `kernelDB::addFile()` accepts .so paths directly (extracts COs
  internally). No coCache changes needed.
- Resolved design question: pass original file path at startup, remove dispatch-time block
- Updated dossier status from TODO/Blocked → Ready to Start
- Status: Ready to start at step 3

### Session 2026-04-09
- Created dossier after reviewing kerneldb PR #27 and verifying Omniprobe builds/tests
  pass against the PR branch
- Posted review on PR #27 identifying 6 issues that must be resolved
- Documented upstream prerequisites and verification checklist
- Status: TODO (blocked on PR #27 merge and issue resolution)

## Last Verified
Commit: c424906
Date: 2026-04-14

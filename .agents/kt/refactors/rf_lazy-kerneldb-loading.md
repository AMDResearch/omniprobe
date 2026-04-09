# Refactor: Adopt Lazy kernelDB Loading

## Status
- [x] TODO
- [ ] In Progress
- [ ] Blocked (on kerneldb PR #27)
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

## Upstream Dependency: kerneldb PR #27

This refactor depends on [kerneldb PR #27](https://github.com/AMDResearch/kerneldb/pull/27)
("Add lazy loading support for code objects") being merged.

### PR Issues That Must Be Resolved Before Starting

Verify these are fixed when resuming this dossier:

1. **Thread safety in `ensureKernelLoaded()`** — Two concurrent `getKernel("foo")` calls
   both find `foo` in `lazy_kernels_`, both disassemble, both call `addKernel()`. The second
   `addKernel()` replaces the `unique_ptr`, destroying the `CDNAKernel` that the first thread
   already holds a reference to. Omniprobe's handlers run on separate threads and call
   `getKernel()` concurrently — this is a real use-after-free risk.

2. **Temp file leak in `getDisassemblyForSymbol()`** — If `invokeProgram()` returns `false`,
   the temp file is never `unlink`ed.

3. **Unconditional `std::cerr` debug output** — Five `[KDB]` prints to stderr on every lazy
   load would pollute Omniprobe output.

4. **Silent failure in `ensureKernelLoaded()`** — On disassembly failure, the kernel stays in
   `lazy_kernels_` forever. Every subsequent `getKernel()` re-attempts the disassembly, and
   the caller sees only a misleading "kernel does not exist" exception.

5. **`tmpnam()` usage** — TOCTOU-racy; should use `mkstemp()`.

6. **No test coverage for the lazy path** — No way to verify correctness without Omniprobe
   acting as the integration test.

### Verification Checklist (Run When Starting)

```bash
# 1. Check PR #27 is merged
gh pr view 27 --repo AMDResearch/kerneldb --json state -q '.state'
# Should print: MERGED

# 2. Check thread safety fix (look for synchronization in ensureKernelLoaded)
grep -n 'ensureKernelLoaded' external/kerneldb/src/kernelDB.cc

# 3. Check stderr debug output is removed or gated
grep -n 'std::cerr.*\[KDB\]' external/kerneldb/src/kernelDB.cc
# Should return 0 hits, or hits gated by #ifdef DEBUG / log level check

# 4. Check tmpnam is gone
grep -n 'tmpnam' external/kerneldb/src/disassemble.cc
# Should return 0 hits

# 5. Check temp file cleanup
grep -n 'unlink' external/kerneldb/src/disassemble.cc
# Should show cleanup on all paths (success and failure)

# 6. Check lazy path test coverage
ls external/kerneldb/tests/test_lazy* 2>/dev/null || grep -r 'lazy' external/kerneldb/tests/
```

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
- **Tests**: `tests/run_handler_tests.sh` — all 22 handler tests pass
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

### Complication: Code Object Path

At startup (line 237), Omniprobe iterates over shared library files and calls
`kernel_cache_.addFile(file, agent, strFilter)`. The `file` here is the shared library path
(e.g., `/path/to/libhipblaslt.so`). However, `kernelDB::addFile()` expects a code object
path (e.g., an extracted `.hsaco` file).

`coCache::addFile()` internally calls `extractCodeObjects()` to extract `.hsaco` files from
fat binaries. The extracted code object paths are stored in `coCache` but not directly
exposed. We need to either:

1. **Expose code object paths from coCache** — add a method like `getCodeObjectPaths(agent)`
   that returns the list of extracted `.hsaco` files, then iterate and call
   `kdb->addFile(co_path, agent, filter, true)` for each.
2. **Call `addFile(lazy=true)` at dispatch time** — keep the dispatch-time location but
   replace `scanCodeObject` with `addFile(lazy=true)` + rely on `getKernel()` to trigger
   the load. This avoids the code object path problem but adds per-dispatch overhead for
   the `addFile` call (though the `scanned_code_objects_` set would prevent re-scanning).
3. **Have coCache return code object paths during addFile** — modify `coCache::addFile()` to
   return the list of extracted code object paths.

**Recommendation**: Option 1 is cleanest. Survey `coCache` to see if code object paths are
already stored and just need a getter.

### Risks
- **Latency shift**: Disassembly cost moves from first-dispatch-of-any-kernel-in-CO to
  first-dispatch-of-each-kernel. If many distinct kernels are dispatched, the total wall time
  is higher (N separate `llvm-objdump --disassemble-symbols` invocations vs one full
  disassembly). For Omniprobe's typical use case (few kernels, large COs), this is a net win.
- **Error visibility**: If `ensureKernelLoaded()` fails silently (upstream issue #4), the
  handler will get a confusing exception. Verify the upstream fix before adopting.

## Plan of Record

### Micro-steps

1. [ ] **Verify upstream prerequisites** — Gate: all checklist items pass
   - Pull latest kerneldb with PR #27 merged
   - Run verification checklist (see above)
   - If any item fails, stop and update dossier status to Blocked

2. [ ] **Survey coCache for code object path access** — Gate: none (research)
   - Check how `coCache::addFile()` stores extracted code object paths
   - Determine if a getter exists or needs to be added
   - Decide between options 1/2/3 from the "Complication" section

3. [ ] **Add lazy addFile calls at startup** — Gate: build
   - After `kernel_cache_.addFile()` in the startup loop (line 237), call
     `kdb->addFile(co_path, agent, filter, true)` for each code object
   - Same for `addCodeObject()` path (line 302)

4. [ ] **Remove scanCodeObject dispatch-time block** — Gate: build + tests
   - Remove lines 802-808 in `interceptor.cc` (the `hasKernel` / `scanCodeObject` block)
   - `getKernel()` in handlers will now trigger lazy loading automatically

5. [ ] **Run full test suite** — Gate: all tests pass
   - Handler tests: 22/22
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
Not started — blocked on kerneldb PR #27 merge and issue resolution.

## Design Decisions
None yet — pending upstream merge.

## Rejected Approaches
None yet.

## Open Questions
1. Which code-object-path approach (1/2/3) is best? Requires surveying `coCache`.
2. Should we add a fallback to `scanCodeObject()` if lazy loading fails for a kernel?
   (Probably not — better to surface the error.)

## Progress Log

### Session 2026-04-09
- Created dossier after reviewing kerneldb PR #27 and verifying Omniprobe builds/tests
  pass against the PR branch
- Posted review on PR #27 identifying 6 issues that must be resolved
- Documented upstream prerequisites and verification checklist
- Status: TODO (blocked on PR #27 merge and issue resolution)

## Last Verified
Commit: N/A
Date: 2026-04-09

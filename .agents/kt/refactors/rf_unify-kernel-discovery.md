# Refactor: Unify Kernel Discovery Data Structures

## Status
- [x] TODO
- [ ] In Progress
- [ ] Blocked
- [ ] Done

## Objective

Eliminate the need for `--library-filter include` in cases where instrumented
kernels (`__amd_crk_*`) and their originals are loaded from the same file by the
application itself (e.g., hipBLASLt's `.hsaco` files loaded via `hipModuleLoad()`).

## Problem Statement

The interceptor has two independent kernel discovery mechanisms that don't share
information:

1. **`kernel_objects_`** (Mechanism 1): Populated via the `hsa_executable_symbol_get_info()`
   hook. Captures ALL kernel handles — including `__amd_crk_*` symbols — regardless
   of loading mechanism (.hip_fatbin, .co, .hsaco, hipModuleLoad). Always on.

2. **`kernel_cache_`** / coCache (Mechanism 2): Populated at startup by scanning
   `/proc/self/maps` libraries (`.hip_fatbin` sections) plus explicit `--library-filter`
   includes. Only this structure is consulted by `findInstrumentedAlternative()`.

When an application loads a file containing both original and instrumented kernels
at runtime (e.g., hipBLASLt loading an instrumented `.hsaco` via `hipModuleLoad()`),
Mechanism 1 captures all the symbols — but Mechanism 2 never sees the file. The
instrumented alternatives are right there in `kernel_objects_` but invisible to the
alternative-matching logic.

**Current workaround**: Users must pass `--library-filter` with an `include` entry
pointing to the same `.hsaco` file the application already loads. This is redundant
and non-obvious.

**Affected case**: hipBLASLt matrix transform kernels (compiled as standalone `.hsaco`,
loaded via `hipModuleLoad()` at runtime).

**Not affected**: rocBLAS non-Tensile kernels (embedded in `librocblas.so`'s
`.hip_fatbin` section, auto-discovered via `/proc/self/maps`).

## Complications

1. **coCache carries metadata beyond kernel handles**: `findInstrumentedAlternative()`
   doesn't just find the alternative handle — coCache also stores:
   - **Argument descriptors** (`arg_map_`): needed by `fixupKernArgs()` to inject
     the dh_comms pointer into the instrumented kernel's arguments
   - **Code object references** (`kernel_co_map_`): needed for on-demand kernelDB
     scanning (disassembly, DWARF extraction)

   Simply looking up `__amd_crk_*` in `kernel_objects_` would find the handle but
   lack these metadata. The HSA hook would need to extract argument descriptors at
   symbol resolution time, or coCache would need to lazily populate metadata from
   `kernel_objects_` on first match.

2. **Timing**: The approach relies on `hipModuleLoad()` resolving all symbols
   before the first dispatch. This appears to hold (HSA loads all symbols when
   creating an executable), but needs verification.

3. **Scope of benefit**: This only helps the "same-file" case (instrumented .hsaco
   replaces original .hsaco). The "external-file" case — where the instrumented
   code object is a separate file the application never loads — would still require
   `--library-filter include`.

## Refactor Contract

### Goal
Allow the interceptor to find instrumented alternatives from dynamically loaded
code objects without requiring explicit `--library-filter` configuration, when
both original and instrumented kernels are in the same file.

### Non-Goals / Invariants
- `--library-filter` must continue to work for the external-file case
- No changes to the instrumentation plugin or kernel naming convention
- No performance regression at dispatch time
- Threading model unchanged

### Verification Gates
- Build: `ninja`
- Tests: `./tests/run_handler_tests.sh` (all 12 pass)
- Tests: `./tests/run_all_tests.sh` (all suites pass)
- Runtime: hipBLASLt test passes WITHOUT `--library-filter` when instrumented
  .hsaco replaces original in custom installation

## Scope

### Affected Symbols
- `hsaInterceptor::kernel_objects_` — may need richer entries or cross-reference
- `coCache::findInstrumentedAlternative()` — needs fallback to kernel_objects_
- `coCache::arg_map_` — may need alternative population path
- `hsaInterceptor::fixupPacket()` — may need updated lookup logic

### Expected Files
- `src/interceptor.cc` — confirmed
- `inc/interceptor.h` — confirmed
- `src/utils.cc` (coCache implementation) — confirmed
- `inc/utils.h` (coCache definition) — confirmed

### Risks
- Argument descriptor extraction at HSA hook time may not be straightforward
- Lazy metadata population adds complexity to the dispatch hot path
- Edge cases with multiple code objects containing same-named kernels
- Thread safety: `runtime_kernels_` is written from the HSA symbol hook (any thread that
  loads a module) while `findInstrumentedAlternative()` reads from the dispatch path.
  A `shared_mutex` (read-heavy, write-rare) is likely appropriate, but needs care to
  avoid contention on the dispatch hot path.

## Proposed Approach: KernelRegistry

Introduce a new **KernelRegistry** class that replaces both `kernel_objects_` and
`kernel_cache_` (coCache), unifying the two kernel discovery mechanisms under a single
owner. kernelDB remains unchanged as a pure analysis library.

### Ownership

```
hsaInterceptor
  |-- KernelRegistry registry_       (replaces kernel_objects_ + kernel_cache_)
  |     |-- runtime_kernels_          agent -> (name -> {name, symbol, agent, kernarg_size})
  |     |                             Populated by HSA symbol hook (replaces kernel_objects_)
  |     |-- cache_kernels_            agent -> (name -> {symbol, kernel_object})
  |     |                             Populated at startup from file scans (replaces lookup_map_)
  |     |-- arg_map_                  agent -> (name -> arg_descriptor_t)
  |     |-- kernel_co_map_            agent -> (name -> CodeObjectRef)
  |     |-- alternatives_             agent -> (symbol -> kernel_object)  [result cache]
  |     |-- kernarg_sizes_            kernel_object -> uint32_t
  |     |-- executables_              HSA executable lifecycle (from cache_objects_)
  |
  |-- kdbs_                           agent -> unique_ptr<kernelDB>  [unchanged]
```

### findInstrumentedAlternative with fallback

1. Check `alternatives_` cache (fast path, unchanged)
2. Compute instrumented name via `getInstrumentedName()`
3. Search `cache_kernels_[agent][instrumented_name]` — existing path
4. **NEW**: Search `runtime_kernels_[agent][instrumented_name]` — fallback path
5. On hit from either path: resolve kernel_object, cache in `alternatives_`, return

Step 4 closes the gap: for dynamically loaded `.hsaco` files where both original and
instrumented kernels are in the same file, the HSA hook has already captured everything.

### Lazy arg descriptor extraction

When the alternative is found via the runtime fallback (step 4), `arg_map_` won't have
an entry yet. The registry lazily extracts it:
- Use the HSA symbol handle from `runtime_kernels_` to query kernarg segment size
- Use the AMD loader API to get the code object bits
- Pass those bits to `KernelArgHelper` to extract COMGR metadata into `arg_descriptor_t`
- Cache the result in `arg_map_`

This adds a one-time cost to the first dispatch of a runtime-discovered instrumented
kernel; subsequent dispatches hit the caches.

Similarly, `kernel_co_map_` would need lazy population for kernelDB's on-demand
`scanCodeObject()` path.

## Plan of Record

### Micro-steps

Phase 1 — Unify ownership:
- Create KernelRegistry class with `runtime_kernels_` (move from `kernel_objects_`)
- Move coCache's maps into KernelRegistry, retire coCache as a separate class
- Interceptor calls KernelRegistry instead of coCache; behavior unchanged

Phase 2 — Add fallback search:
- Add runtime fallback path to `findInstrumentedAlternative()` (step 4 above)
- Add lazy `arg_descriptor_t` extraction for runtime-discovered kernels
- Add lazy `kernel_co_map_` population for runtime-discovered kernels

Phase 3 — Verify:
- hipBLASLt test passes WITHOUT `--library-filter` for same-file case
- All existing tests pass (no regression)
- `--library-filter` still works for external-file case

## Progress Log

### Session 2026-03-17
- Explored all three data stores in detail (kernel_objects_, coCache maps, kernelDB internals)
- Evaluated and rejected merging coCache into kernelDB (analysis-only vs. runtime state)
- Proposed KernelRegistry approach with two-source fallback search
- Identified lazy arg descriptor extraction mechanism (AMD loader API + KernelArgHelper)
- Added incremental phasing plan (3 phases)
- Added thread safety risk (shared_mutex for concurrent hook writes vs. dispatch reads)
- Wrote discussion document: `.untracked/unify_kernel_discovery.md`
- Removed resolved open questions; refined remaining ones

### Session 2026-03-06
- Created dossier from architectural discussion during hipBLASLt instrumentation work
- Identified the two-mechanism gap and complications
- Status: TODO (exploration needed before committing to an approach)

## Rejected Approaches

### Merge coCache functionality into kernelDB

**Rationale for considering**: kernelDB already extracts code objects
(`extractCodeObjects()`), handles the `__amd_crk_*` naming convention in
`demangleName()`, and stores kernel names and arguments. If `kernel_objects_` data also
lived in kernelDB, `findInstrumentedAlternative()` could search everything in one place.

**Why rejected**: kernelDB is currently a pure analysis library — it takes a code object
file and an agent, returns disassembly, DWARF mappings, and argument metadata. It stores
zero HSA runtime state (no executable handles, no symbols, no kernel object addresses).
Moving coCache functionality in would require it to:

1. Manage HSA executable lifecycle (create, load, freeze, destroy)
2. Store HSA handles (`hsa_executable_symbol_t`, kernel object addresses, `alternatives_`)
3. Extract COMGR metadata for `arg_descriptor_t` (a second arg extraction path alongside
   its existing DWARF-based one)
4. Participate in the dispatch hot path (performance-critical, unlike its current lazy
   invocation for ISA analysis)
5. Accept a dependency on `HsaApiTable*` (currently depends only on `hsa_agent_t` + COMGR)

The result would be a hybrid analysis/runtime-state-management class with two different
performance profiles and lifecycle concerns. kernelDB is also a git submodule shared
across projects; adding HSA runtime coupling would reduce its reusability.

## Open Questions
- Can argument descriptors be reliably extracted at `hsa_executable_symbol_get_info()` hook
  time, or must we defer to dispatch time? (Proposed approach: lazy extraction at first
  dispatch, using AMD loader API + KernelArgHelper.)
- Are there cases where `hipModuleLoad()` resolves symbols after the first dispatch?
- For lazy `kernel_co_map_` population: can the AMD loader API reverse-lookup the code
  object from a symbol handle, or do we need to also hook
  `hsa_executable_load_agent_code_object()` to capture code object data at load time?

## Last Verified
Commit: N/A
Date: 2026-03-17

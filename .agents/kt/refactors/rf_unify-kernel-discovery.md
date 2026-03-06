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

## Plan of Record

### Micro-steps
Not yet planned. Requires exploration session to determine approach.

## Progress Log

### Session 2026-03-06
- Created dossier from architectural discussion during hipBLASLt instrumentation work
- Identified the two-mechanism gap and complications
- Status: TODO (exploration needed before committing to an approach)

## Rejected Approaches
None yet.

## Open Questions
- Can argument descriptors be reliably extracted at `hsa_executable_symbol_get_info()` hook time?
- Would a lazy coCache population (on first dispatch miss) be acceptable performance-wise?
- Are there cases where `hipModuleLoad()` resolves symbols after the first dispatch?
- Should this be a merge of data structures or just a fallback path in `findInstrumentedAlternative()`?

## Last Verified
Commit: N/A
Date: 2026-03-06

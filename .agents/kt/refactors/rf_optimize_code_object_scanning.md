# Refactor: Optimize Code Object Scanning

## Status
- [ ] TODO
- [x] In Progress
- [ ] Blocked
- [ ] Done

## Objective

Reduce the startup time of omniprobe when running with instrumentation
(`LOGDUR_INSTRUMENTED=true`). Currently, the interceptor constructor scans ALL code
objects in ALL linked libraries — extracting code objects, disassembling them, and
building source maps — even when the application dispatches just one kernel. For large
libraries like rocBLAS (~50 code objects, 12,000+ kernels), this takes over 10 minutes
and never completes.

### Target architecture

Replace the current "scan everything at startup" model with **on-demand per-kernel
scanning**. Only retrieve disassembly and DWARF info for kernels whose instrumented
versions are actually dispatched, and only for the original (uninstrumented) kernel.

### Performance baseline (measured in `.untracked/isa_scanning.md`)

| Scenario | coCache::addFile | kernelDB extraction | kernelDB disassembly | Total |
|---|---|---|---|---|
| Simple kernel (10 kernels) | 8 ms | 1 ms | 121 ms | 140 ms |
| rocBLAS (~50 COs, 12K+ kernels) | 14.8 s | 1.5 s | >10 min (timeout) | >10 min |

### Target performance

- Startup: coCache scan only (no kernelDB scan). ~15 s for rocBLAS.
- Per-dispatch overhead: ~100-200 ms for first dispatch of each unique kernel (one code
  object extraction + single-symbol disassembly + DWARF for that code object).
- Subsequent dispatches of the same kernel: 0 ms (cached).

## Refactor Contract

### Goals

1. **On-demand scanning**: Move `kernelDB::addFile()` out of the startup path. Instead,
   get disassembly and DWARF info per-kernel at dispatch time, only for dispatched
   instrumented kernels.
2. **Deduplicate code**: Consolidate fat-binary parsing so it happens once. Eliminate
   copy-pasted utility functions between `src/utils.cc` and `kernelDB.cc`.
3. **Preserve kernelDB's existing full-scan API** for other users. The new per-kernel
   API is additive.

### Non-Goals / Invariants
- ABI compatibility: n/a (internal code)
- API compatibility: kernelDB public API (`kernelDB.h`) — new methods are additive.
  Existing `addFile()` and full-scan API must continue to work for other kernelDB users.
- Performance constraints: must not regress startup time for simple cases (~140 ms).
  Must not add more than ~200 ms per first dispatch of a unique instrumented kernel.
- Threading model: `coCache` uses `std::mutex`, `kernelDB` uses `std::shared_mutex`.
  On-demand calls happen during dispatch, which is already on a per-dispatch thread.
  Locking must be preserved.
- Existing tests (`tests/run_handler_tests.sh`) must continue to pass.
- Triton cache watcher path (`cache_watcher()` → `addCodeObject()`) must still work.

### Verification Gates
- Build: `cd build && cmake --build . -j$(nproc)`
- Tests: `tests/run_all_tests.sh`
- Timing: run dual_kernel_test, simple_heatmap_test, and (where feasible) rocBLAS test
  with `[TIMING]` output to verify improvements

## Scope

### Duplicated Code Inventory

**Identical functions (copy-pasted):**

| Function | `src/utils.cc` | `external/kerneldb/src/kernelDB.cc` |
|---|---|---|
| `demangleName()` | line 92 | line 99 |
| `getIsaList()` | line 181 | line 179 |

**Functionally duplicated (same logic, minor signature differences):**

| Function | KernelArgHelper (`src/utils.cc`) | kernelDB (`kernelDB.cc`) |
|---|---|---|
| `getElfSectionBits()` | line 1065 (no offset out-param) | line 624 (returns offset) |
| `findCodeObjectOffsets()` | line 835 (returns `vector<size_t>`) | line 675 (returns `vector<BundleOffsetSize>`) |
| `getCodeObjectInfo()` | line 933 | line 776 |

**Redundant re-read within kernelDB:**
- `addFile()` calls `extractCodeObjects()` → reads `.hip_fatbin`, extracts code objects
- `mapDisassemblyToSource()` → re-reads `.hip_fatbin` again via `getElfSectionBits()` +
  `getCodeObjectInfo()` to build DWARF maps

**Duplicate fat-binary parsing across codebases:**
- `coCache::addFile()` calls `KernelArgHelper::getElfSectionBits()` +
  `KernelArgHelper::getCodeObjectInfo()` to find code objects, then creates HSA executables
- `kernelDB::addFile()` calls `extractCodeObjects()` which calls
  `kernelDB::getElfSectionBits()` + `kernelDB::getCodeObjectInfo()` for the same purpose
- Both operate on the same file, reading `.hip_fatbin` twice independently

### Unique Functionality Per Component

**coCache owns (cannot move to kernelDB):**
- HSA executable creation, loading, freezing (requires `HsaApiTable*`)
- HSA symbol iteration (`hsa_executable_iterate_symbols_fn`)
- `lookup_map_[agent][name]` → symbol handle for dispatch-time alternative lookup
- `arg_map_[agent][name]` → `arg_descriptor_t` for kernarg buffer construction
- `KernelArgHelper::getArgDescriptor()` — comgr-based arg metadata

**kernelDB owns:**
- Code object extraction to temp files (`extractCodeObjects()`, `co_extract.cc`)
- Disassembly via `llvm-objdump` (`getDisassembly()`, `parseDisassembly()`)
- DWARF source mapping (`buildDwarfAddressMap()`, `processKernelsWithAddressMap()`)
- DWARF-based argument extraction (`extractArgumentsFromDwarf()` → `KernelArgument`)

### Arg Descriptor: Two Mechanisms

`coCache` needs `arg_descriptor_t` (from comgr metadata):
```c
typedef struct arg_descriptor {
    size_t explicit_args_length;
    size_t explicit_args_count;
    size_t hidden_args_length;
    size_t kernarg_length;
    uint32_t private_segment_size;
    uint32_t group_segment_size;
    size_t clone_hidden_args_length;
} arg_descriptor_t;
```
Used in `fixupKernArgs()` to construct modified dispatch packets.

`kernelDB` produces `KernelArgument` (from DWARF):
```c
struct KernelArgument {
    std::string name, type_name;
    size_t size, offset, alignment;
    uint32_t position;
    std::vector<KernelArgument> members;
};
```
Used for source-level analysis reporting.

**Open question**: Can `KernelArgument` data (from DWARF) replace `arg_descriptor_t`
(from comgr)? The comgr metadata provides `explicit_args_length`, `hidden_args_length`,
`private/group_segment_size`, `clone_hidden_args_length`. DWARF-based extraction may not
have hidden arg info or segment sizes. Needs investigation (see step 1.0).

### On-Demand Scanning: Key Design Points

**What coCache scan #1 already provides per kernel:**
- Kernel name (demangled and mangled)
- HSA symbol handle
- Which file it came from
- Which code object within that file (iterates executables per code object)

**What coCache must additionally record** during scan #1:
- `kernel_name → (file_path, code_object_index)` — so we know where to find
  the original kernel's code object later without re-scanning
- The mangled symbol name — currently discarded after demangling (line 442 in
  utils.cc), needed for `--disassemble-symbols` flag

**Per-kernel disassembly is supported:**
`llvm-objdump --disassemble-symbols=<mangled_name>` is available on this system
(ROCm 7.1.0). This disassembles only the named symbol, avoiding the cost of
disassembling all kernels in a code object.

**Per-kernel DWARF is partially feasible:**
`buildDwarfAddressMap()` builds a full address→source map for a code object.
For on-demand use, we build the map for a single code object (not all 50+),
then filter to the kernel's address range (known from disassembly output).
This is much faster than building maps for all code objects. Similarly,
`extractArgumentsFromDwarf()` can filter to the specific kernel name.

**Proposed on-demand flow:**

At startup:
1. `coCache::addFile()` runs as before — iterates all code objects, discovers all
   kernel symbols, builds lookup maps. Records `kernel → code_object` mapping.
2. **No `kernelDB::addFile()` at startup.** This eliminates the >10 min bottleneck.

At dispatch time (when an instrumented kernel is dispatched):
1. `fixupPacket()` finds the instrumented alternative in coCache (already works).
2. Looks up which code object contains the original kernel (new mapping from step 1).
3. Calls a new kernelDB API to get disassembly + DWARF for that one kernel:
   a. Extract just that one code object from the fat binary (if not already cached).
   b. Disassemble just that one kernel via `--disassemble-symbols=<mangled_name>`.
   c. Build DWARF address map for just that code object.
   d. Return `CDNAKernel` for the requested kernel.
4. Result is cached — subsequent dispatches of the same kernel pay no cost.

### Affected Symbols
- `coCache::addFile()` — `src/utils.cc:312` (augment to record code object mapping)
- `KernelArgHelper` class — `inc/utils.h:182`, `src/utils.cc:784+`
- `KernelArgHelper::getElfSectionBits()` — `src/utils.cc:1065` (remove)
- `KernelArgHelper::getCodeObjectInfo()` — `src/utils.cc:933` (remove)
- `findCodeObjectOffsets()` (in utils.cc) — `src/utils.cc:835` (remove)
- `demangleName()` (in utils.cc) — `src/utils.cc:92` (remove, use kernelDB's)
- `getIsaList()` (in utils.cc) — `src/utils.cc:181` (remove, use kernelDB's)
- `kernelDB::addFile()` — `external/kerneldb/src/kernelDB.cc:294` (keep for other users)
- `kernelDB` new API — per-kernel disassembly + DWARF (new)
- `kernelDB::mapDisassemblyToSource()` — `external/kerneldb/src/kernelDB.cc:842` (fix double-read)
- `extractCodeObjects()` — `external/kerneldb/src/co_extract.cc:29` (add single-CO variant)
- `getDisassembly()` — `external/kerneldb/src/disassemble.cc:63` (add per-symbol variant)
- `hsaInterceptor` constructor — `src/interceptor.cc:154` (remove `kdbs_` addFile loop)
- `hsaInterceptor::fixupPacket()` — `src/interceptor.cc` (add on-demand kernelDB call)

### Expected Files
- `src/utils.cc` — confirmed (remove duplicated functions, refactor coCache::addFile)
- `inc/utils.h` — confirmed (KernelArgHelper class may shrink, new code_object mapping type)
- `src/interceptor.cc` — confirmed (remove startup kernelDB loop, add on-demand call in fixupPacket)
- `external/kerneldb/src/kernelDB.cc` — confirmed (new per-kernel API, fix double-read)
- `external/kerneldb/include/kernelDB.h` — confirmed (new public API)
- `external/kerneldb/src/co_extract.cc` — confirmed (single-CO extraction variant)
- `external/kerneldb/src/disassemble.cc` — confirmed (per-symbol disassembly)

### Risks
- **Risk**: kernelDB is a submodule used by other projects. Changing its public API could
  break them.
  **Mitigation**: Add new methods; keep existing `addFile()` intact. New API is additive.
- **Risk**: `KernelArgHelper` comgr-based arg metadata may not be replaceable by DWARF.
  **Mitigation**: Investigate first (step 1.0). If not replaceable, keep `KernelArgHelper`
  but have it consume code objects from kernelDB instead of re-parsing fat binaries.
- **Risk**: `--disassemble-symbols` might not work correctly for all kernel name formats
  (e.g., heavily mangled C++ names, Tensile kernel names).
  **Mitigation**: Test with both simple kernels and rocBLAS kernels. Fall back to full
  code-object disassembly if single-symbol fails.
- **Risk**: On-demand call during dispatch adds latency to first dispatch of each kernel.
  **Mitigation**: ~100-200 ms per unique kernel is acceptable. Could be parallelized or
  made async in the future if needed.
- **Risk**: Thread safety of on-demand kernelDB calls during dispatch.
  **Mitigation**: kernelDB already uses `shared_mutex`. On-demand calls take write lock
  to add new kernels, or build a local `CDNAKernel` and return it.
- **Risk**: Timing instrumentation is still in the code and must be removed before merge.
  **Mitigation**: Tracked as final step in this dossier.

## Plan of Record

### Phase 1: Deduplication and cleanup

Consolidate fat-binary parsing, eliminate copy-pasted functions, fix internal
redundancies. This is groundwork that simplifies Phase 2.

#### 1.0: Investigate arg_descriptor_t vs KernelArgument
Determine whether DWARF-based `KernelArgument` can provide the same information as
comgr-based `arg_descriptor_t`. Specifically check:
- Can we derive `explicit_args_length`, `hidden_args_length` from DWARF data?
- Does DWARF provide `private_segment_size`, `group_segment_size`?
- Does DWARF provide `clone_hidden_args_length`?
- Gate: document findings, no code changes

#### 1.1: Eliminate identical utility functions
Move `demangleName()` and `getIsaList()` to kernelDB (they're already there). Delete
the copies from `src/utils.cc`. Have `coCache` call `kernelDB::demangleName()` and
`kernelDB::getIsaList()`.
- Gate: build + `tests/run_all_tests.sh`
- Test: existing tests pass (these are pure utility functions with no behavioral change)

#### 1.2: Fix the double fat-binary read in kernelDB
`mapDisassemblyToSource()` re-reads the fat binary even though `addFile()` already
extracted the code objects to temp files. Change `mapDisassemblyToSource()` to use
the already-extracted temp hsaco files from `file_map_` for DWARF parsing, instead of
re-reading the original binary.
- Gate: build + `tests/run_all_tests.sh`
- Test: verify with dual_kernel_test that `[TIMING]` output for kernelDB phase 3 is
  unchanged or improved. Verify DWARF source mapping still works correctly by checking
  that MemoryAnalysis output includes source file/line references.

#### 1.3: Expose code-object info from kernelDB for coCache consumption
Add a method to kernelDB that returns the extracted code object data (paths to temp
hsaco files, or byte ranges within the fat binary) so that coCache can use them instead
of independently parsing the fat binary.
- Possible API: `kernelDB::getExtractedCodeObjects(filename)` returning file paths, or
  `kernelDB::getCodeObjectBytes(filename, index)` returning byte spans.
- Gate: build (new API, no callers yet)

#### 1.4: Refactor coCache::addFile() to use kernelDB's code objects
Change `coCache::addFile()` to:
1. Call kernelDB to get the list of code objects (instead of calling
   `KernelArgHelper::getElfSectionBits` + `getCodeObjectInfo`)
2. Create HSA executables from the code objects kernelDB already extracted
3. Keep its own HSA symbol iteration and lookup map construction
- Gate: build + `tests/run_all_tests.sh`
- Test: verify `[TIMING]` output shows `coCache::addFile` time is unchanged or reduced

#### 1.5: Remove duplicated fat-binary parsing from KernelArgHelper
After 1.4, `KernelArgHelper` no longer needs its own `getElfSectionBits()`,
`findCodeObjectOffsets()`, or `getCodeObjectInfo()`. Remove them. `KernelArgHelper` keeps
only `getArgDescriptor()` / `computeKernargData()` (its unique functionality), and receives
code object bytes from kernelDB rather than parsing fat binaries itself.
- Gate: build + `tests/run_all_tests.sh`

### Phase 2: On-demand per-kernel scanning

Eliminate the `kernelDB::addFile()` call at startup. Instead, get disassembly and
DWARF info per-kernel at dispatch time.

#### 2.0: Augment coCache to record code-object provenance
During `coCache::addFile()`, record for each kernel:
- The source file path
- The code object index within that file (or offset+size within `.hip_fatbin`)
- The mangled symbol name (currently discarded after demangling at line 442)
New data structure: `kernel_co_map_[agent][name] → CodeObjectRef{file, co_index, mangled_name}`
- Gate: build + `tests/run_all_tests.sh`
- Test: add a unit test or debug print that verifies the mapping is populated correctly
  for dual_kernel_test (both kernel_alpha and kernel_beta should have entries)

#### 2.1: Add per-symbol disassembly to kernelDB
Add `getDisassemblyForSymbol(agent, hsaco_path, mangled_symbol_name)` to kernelDB.
This calls `llvm-objdump --disassemble-symbols=<name>` instead of `-d`, and parses
the output into a single `CDNAKernel`.
- Gate: build
- Test: write a test (or temporary debug code) that calls the new function for a known
  kernel in dual_kernel_test's binary and verifies the returned `CDNAKernel` has the
  expected basic blocks and instructions. Compare output with full-disassembly result
  to confirm equivalence.

#### 2.2: Add single-code-object extraction to kernelDB
Add `extractSingleCodeObject(agent, file_path, co_index)` that extracts just one code
object from a fat binary (by index or offset+size), returning the temp hsaco path.
Cache extracted code objects to avoid re-extraction.
- Gate: build
- Test: verify that extracting CO index 0 from dual_kernel_test binary produces the
  same temp file content as `extractCodeObjects()` produces for index 0.

#### 2.3: Add per-kernel DWARF + disassembly API to kernelDB
Combine 2.1 and 2.2 into a high-level API:
`kernelDB::getKernelInfo(agent, file_path, co_index, mangled_name)` → `CDNAKernel`
This:
1. Extracts the code object if not already cached (2.2)
2. Disassembles just the requested symbol (2.1)
3. Builds DWARF address map for that code object (reuse existing `buildDwarfAddressMap`)
4. Maps disassembly to source for the returned kernel
5. Caches the result in `kernels_`
- Gate: build
- Test: call `getKernelInfo()` for kernel_alpha from dual_kernel_test, verify it returns
  a valid `CDNAKernel` with source mappings. Call it again, verify it returns the cached
  result (no second llvm-objdump invocation — verify via timing or debug print).

#### 2.4: Remove kernelDB::addFile() from interceptor startup
Change the interceptor constructor to NOT call `kdbs_[agent]->addFile()` in the startup
loop. Instead, `kdbs_[agent]` is created but left empty.
- Gate: build + `tests/run_all_tests.sh`
- Test: verify startup timing for dual_kernel_test drops (no kernelDB scanning at startup).
  **Tests may fail at this point** if the dispatch path still expects kernelDB to be
  populated — that's fixed in 2.5.

#### 2.5: Wire on-demand scanning into dispatch path
In `fixupPacket()` (or `comms_mgr_.checkoutCommsObject()`), when an instrumented kernel
is dispatched:
1. Look up the original kernel's `CodeObjectRef` from coCache (from step 2.0)
2. Call `kernelDB::getKernelInfo()` (from step 2.3) to get the `CDNAKernel` on demand
3. Pass the populated kernelDB to the comms object as before
- Gate: build + `tests/run_all_tests.sh`
- Test: run dual_kernel_test with MemoryAnalysis — verify output includes source file/line
  references (proves on-demand DWARF mapping works). Verify `[TIMING]` output shows
  kernelDB work happening at dispatch time, not startup. Verify rocBLAS scal test starts
  within seconds (not minutes).

#### 2.6: Verify Triton cache watcher path
The `cache_watcher()` → `addCodeObject()` path calls both `kernel_cache_.addFile()` and
`kdbs_[agent]->addFile()`. With on-demand scanning, the `kdbs_` call should also be
deferred. Verify this path works correctly (may need `CodeObjectRef` to be populated
for dynamically-added kernels too).
- Gate: build (Triton path is hard to test without Triton)
- Test: code review to verify the path is consistent with the new architecture

### Phase 3: Cleanup

#### 3.0: Remove timing instrumentation
Remove all `[TIMING]` debug prints and the `#include <chrono>` added during investigation.
- Files: `src/interceptor.cc`, `external/kerneldb/src/kernelDB.cc`
- Gate: build + `tests/run_all_tests.sh`

#### 3.1: Remove dual_kernel_test (if not needed long-term)
Decide whether `dual_kernel_test` should remain as a permanent test or was only needed
for this investigation.
- Gate: discuss with user

### Current Step
Step 1.0: Investigate arg_descriptor_t vs KernelArgument

## Progress Log

### Session 2026-03-05
- Completed: ISA scanning investigation (see `.untracked/isa_scanning.md`)
  - Identified 2 independent scans per file at startup
  - Measured timing: rocBLAS takes >10 min, dominated by disassembly
  - All scanning happens once at startup, not per-dispatch
- Completed: Duplication analysis between coCache and kernelDB
  - Found 5 duplicated functions (2 identical, 3 functionally equivalent)
  - Found redundant double-read of fat binaries within kernelDB
  - Identified unique responsibilities of each component
- Confirmed: `llvm-objdump --disassemble-symbols=<value>` is available on ROCm 7.1.0
- Confirmed: on-demand per-kernel scanning is feasible
- Created: `optimize_code_object_scans` branches in main repo and kernelDB
- Created: Timing instrumentation (temporary, to be removed in phase 3)
- Created: `tests/test_kernels/dual_kernel_test.cpp` for dual-dispatch validation
- Created: refactor dossier
- Gates: build passes, dual_kernel_test runs correctly
- Next: Step 1.0 — investigate arg_descriptor_t vs KernelArgument

## Rejected Approaches
(None yet)

## Open Questions
1. Can `KernelArgument` (DWARF) replace `arg_descriptor_t` (comgr)? Specifically, does
   DWARF provide hidden arg info and segment sizes? (Addressed by step 1.0)
2. Should kernelDB expose code objects as file paths (temp hsacos) or as in-memory byte
   spans? File paths are simpler but require disk I/O; byte spans avoid temp files but
   require holding memory. (To be decided in step 1.3 / 2.2)
3. The Triton cache watcher path must work with the new architecture. (Addressed by
   step 2.6)
4. Should `--disassemble-symbols` fall back to full `-d` if the symbol name doesn't
   match? Or should it be an error? (To be decided in step 2.1)
5. What is the actual per-kernel latency for `--disassemble-symbols` on a large code
   object (e.g., one of rocBLAS's code objects with 500+ kernels)? Need to measure.
   (To be measured in step 2.1)

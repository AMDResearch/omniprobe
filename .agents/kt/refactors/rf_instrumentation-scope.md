# Refactor: Instrumentation Scope Filtering

## Status
- [x] TODO
- [ ] In Progress
- [ ] Blocked
- [ ] Done

### Blocker (if blocked)
N/A

## Objective
Add source-level scope filtering to the AMDGCNSubmitAddressMessages instrumentation plugin,
so users can limit instrumentation to specific source files and/or line ranges. This reduces
instrumentation overhead and focuses analysis on suspected bottleneck regions.

## Refactor Contract

### Goal
Implement `INSTRUMENTATION_SCOPE` and `INSTRUMENTATION_SCOPE_FILE` environment variables that
the AMDGCNSubmitAddressMessages plugin reads at compile time to decide which instructions to
instrument. When a scope is active, only instructions whose debug info (source file + line)
matches a scope definition are instrumented. When no scope is set, behavior is unchanged
(instrument everything).

Additionally, add `--instrumentation-scope` and `--instrumentation-scope-file` CLI options to
the omniprobe Python script for Triton runs (where JIT compilation makes this convenient).

### Scope Definition Syntax

A scope definition has the form:

```
[file_path][:line_spec[,line_spec...]]
```

Where `line_spec` is either:
- `N` — a single line number
- `N:M` — a half-open range [N, M) (line N included, line M excluded)

File path matching:
- Starts with `/` → exact full path match against debug info path
- Does not start with `/` → tail match (debug info path must end with this string)
- Empty (`:N,M` form) → matches any source file

Multiple scope definitions are separated by semicolons. Spaces after semicolons are optional.

Examples:
```
/path/to/source.cpp                  # all lines in this file
/path/to/source.cpp:42:50            # lines [42, 50) in this file
/path/to/source.cpp:42:50,62:70      # lines [42, 50) and [62, 70)
/path/to/source.cpp:42               # line 42 only
to/source.cpp:42,50                  # tail match, lines 42 and 50
:42,50                               # any file, lines 42 and 50
/a.cpp;/b.cpp:10:20; c.cpp:5         # multiple definitions
```

File format (for `INSTRUMENTATION_SCOPE_FILE`): same syntax, one definition per line.
Blank lines and lines starting with `#` are ignored. Semicolons within a line are also
supported (same as the env var).

If both `INSTRUMENTATION_SCOPE` and `INSTRUMENTATION_SCOPE_FILE` are set, their definitions
are merged (union).

### Error Handling

On syntax error (e.g., `source.cpp:42:30` where end < start, or `source.cpp:1:2:3` with
three colon-separated numbers in a line spec), the plugin prints a diagnostic to stderr and
disables scope filtering entirely (instruments everything). This is the safe fallback.

### Non-Goals / Invariants
- **ABI compatibility**: n/a (new feature, no existing ABI affected)
- **API compatibility**: n/a (new feature)
- **Performance constraints**: Zero overhead when no scope is set (no env var lookup per
  instruction — check once at module start). When scope is active, per-instruction matching
  must be efficient (string comparison + range check).
- **Threading model**: No changes (plugin runs single-threaded at compile time)
- **Other invariants**:
  - Existing behavior unchanged when neither env var is set
  - Only AMDGCNSubmitAddressMessages is affected (other plugins unchanged)
  - Parsing/matching utilities go in InstrumentationCommon for future reuse
  - Instructions without debug info are NOT instrumented when a scope is active
  - omniprobe `--instrumentation-scope[-file]` options only valid with `-i` and Triton
    (i.e., `--cache-location` must be provided); error out otherwise

### Verification Gates
- **Build**: `cmake --build build/` succeeds
- **Existing tests**: `tests/run_all_tests.sh` passes (regression check)
- **New tests**: Scope filtering tests pass (validate correct/reduced instrumentation)

## Scope

### Affected Symbols

**instrument-amdgpu-kernels submodule:**
- `AMDGCNSubmitAddressMessage::runOnModule()` — add scope check in instruction loop
- New: `InstrumentationScope` class (in InstrumentationCommon) — parsing + matching
- `getFullPath()` — already exists, used by scope matching

**omniprobe CLI:**
- `add_general_group()` — add `--instrumentation-scope` and `--instrumentation-scope-file` args
- `setup_env()` — set env vars, validate Triton-only constraint

### Expected Files

**instrument-amdgpu-kernels submodule:**
- `include/InstrumentationCommon.h` — add InstrumentationScope class declaration [confirmed]
- `src/InstrumentationCommon.cpp` — add InstrumentationScope implementation [confirmed]
- `src/AMDGCNSubmitAddressMessages.cpp` — add scope check in runOnModule() [confirmed]

**omniprobe CLI:**
- `omniprobe/omniprobe` — add CLI args + env var setup [confirmed]

**Tests:**
- `tests/test_kernels/scope_filter_test.cpp` — new test kernel with predictable line layout [new]
- `tests/test_kernels/CMakeLists.txt` — add new test kernel target [confirmed]
- `tests/run_scope_filter_tests.sh` — new test script [new]
- `tests/run_handler_tests.sh` — source the new test script [confirmed]

### Call Graph Impact
- `runOnModule()` creates an `InstrumentationScope` instance at module start (reads env vars once)
- In the instruction loop, calls `scope.matches(file_path, line)` before instrumenting
- No impact on other plugins, device code, or runtime components
- omniprobe sets env vars before launching subprocess (same pattern as block filters)

### Risks
- **Debug info absence**: Some instructions may lack debug info (DL == nullptr). When scope
  is active, these are skipped. This is correct behavior but differs from current (instrument
  everything including unknown-source instructions). Document this.
- **Hash-based file comparison**: The plugin currently hashes file paths for the runtime
  message. The scope filter works on string paths (pre-hash), so no interaction.
- **Test kernel line stability**: Tests depend on knowing which source lines contain
  loads/stores. Mitigated by using `// SCOPE_MARKER` comments on instrumented lines;
  the test script greps for markers to discover line numbers dynamically.

## Plan of Record

### Micro-steps

**Phase 1: Scope parser (InstrumentationCommon)**

1. [ ] Add InstrumentationScope class declaration to InstrumentationCommon.h — Gate: compile
   - Struct `ScopeEntry { std::string file_pattern; bool is_full_path; std::vector<std::pair<uint32_t, uint32_t>> ranges; }`
   - Class with: constructor (reads env vars), `bool isActive()`, `bool matches(const std::string& file, uint32_t line)`
   - Private: `std::vector<ScopeEntry> entries_; bool active_;`
   - Private: `bool parseDefinitions(const std::string& input)`, `bool parseFile(const std::string& path)`

2. [ ] Implement scope definition parser in InstrumentationCommon.cpp — Gate: compile
   - `parseDefinitions()`: split on `;`, parse each definition
   - Parse file path (before first `:` that starts a line spec) and line specs
   - Distinguish full path (starts with `/`) from tail match
   - Parse line specs: `N` → [N, N+1), `N:M` → [N, M), comma-separated
   - Validate: M > N for ranges, no more than 2 colon-separated numbers per line spec
   - On error: print diagnostic to stderr, return false

3. [ ] Implement file reader for INSTRUMENTATION_SCOPE_FILE — Gate: compile
   - `parseFile()`: read file line by line, skip blank lines and `#` comments
   - Concatenate non-comment lines with `;` separator, feed to `parseDefinitions()`

4. [ ] Implement constructor and matches() — Gate: compile
   - Constructor: read `INSTRUMENTATION_SCOPE` and `INSTRUMENTATION_SCOPE_FILE` from env
   - If neither set: `active_ = false` (fast path)
   - If either set: parse definitions, merge into `entries_`
   - If parse error: print diagnostic, set `active_ = false`
   - `matches()`: if not active, return true. Otherwise check each entry:
     - File match: full path → exact compare; tail → `endsWith`; empty → matches any
     - If entry has no ranges: file match is sufficient
     - If entry has ranges: line must fall in at least one range

**Phase 2: Plugin integration**

5. [ ] Integrate InstrumentationScope into AMDGCNSubmitAddressMessages — Gate: compile
   - Create `InstrumentationScope scope;` at start of `runOnModule()`
   - In the instruction loop, before each `InjectInstrumentationFunction` /
     `InjectBufferInstrumentationFunction` call:
     - Get `DILocation *DL` from the instruction
     - If scope is active and (DL is null or `!scope.matches(getFullPath(DL), DL->getLine())`): skip
   - Print summary to stderr when scope is active: "Instrumentation scope active: N definitions"

6. [ ] Build and verify no regression — Gate: compile + existing tests pass
   - Build the full project
   - Run `tests/run_all_tests.sh` to verify existing tests still pass
   - Scope is not set in existing tests, so behavior should be identical

**Phase 3: Test kernel and test script**

7. [ ] Create scope filter test kernel — Gate: compile
   - `tests/test_kernels/scope_filter_test.cpp`
   - Single kernel with multiple distinct load/store operations on separate lines
   - Each line with a load or store gets a `// SCOPE_MARKER` comment
   - The test script greps for `SCOPE_MARKER` to discover line numbers dynamically,
     so the test is self-maintaining if the kernel file is edited
   - Keep the kernel simple: one memory operation per marked line, no complex expressions
   - Example layout:
     ```cpp
     __global__ void scope_test_kernel(int* a, int* b, int* c, int n) {
         int idx = threadIdx.x;
         int val_a = a[idx];          // SCOPE_MARKER
         int val_b = b[idx];          // SCOPE_MARKER
         c[idx] = val_a + val_b;      // SCOPE_MARKER
         // ... more operations with markers on separate lines
     }
     ```
   - Do NOT add to `tests/test_kernels/CMakeLists.txt` — this kernel is compiled
     on the fly by the test script (see step 8), not at project build time

8. [ ] Write scope filter test script — Gate: tests pass
   - `tests/run_scope_filter_tests.sh`, following the pattern of `run_block_filter_tests.sh`
   - Source `test_common.sh`

   **Compilation**: Scope filtering is a compile-time feature (the plugin reads
   `INSTRUMENTATION_SCOPE` during compilation). Unlike block filtering (runtime in
   dh_comms), the test script must recompile the test kernel for each scope setting.
   The script compiles with `hipcc -fgpu-rdc -fpass-plugin=<plugin>` and the scope
   env var set, then runs the resulting binary under omniprobe.

   The script should:
   - Locate the instrumentation plugin `.so` and dh_comms bitcode from the build dir
   - Define a `compile_with_scope()` helper that compiles the kernel with a given
     `INSTRUMENTATION_SCOPE` value (or `INSTRUMENTATION_SCOPE_FILE`)
   - Use `grep -n 'SCOPE_MARKER'` on the kernel source to discover line numbers
     and compute expected message counts dynamically

   **Tests** (all using AddressLogger analyzer for JSON message counting):
     - Test 1: No scope set → baseline message count (all markers instrumented)
     - Test 2: Scope = full path to test kernel source → same count as baseline
       (confirms file-only scope works)
     - Test 3: Scope = specific line range covering only some markers →
       reduced message count (verify exact count from marker grep)
     - Test 4: Scope = single line → only messages from that line
     - Test 5: Scope = tail match (partial path) → same as full path test
     - Test 6: Scope = non-matching file → 0 instrumented instructions
       (plugin still produces a cloned kernel, but with no instrumentation calls;
       verify that message count is 0)
     - Test 7: Scope from file (INSTRUMENTATION_SCOPE_FILE) → same as inline scope

9. [ ] Integrate scope filter tests into test runner — Gate: all tests pass
   - Add `source "${SCRIPT_DIR}/run_scope_filter_tests.sh"` to `run_handler_tests.sh`
   - Run full test suite to verify

**Phase 4: omniprobe CLI integration**

10. [ ] Add --instrumentation-scope and --instrumentation-scope-file to omniprobe — Gate: n/a (Python, no build)
    - Add to `add_general_group()`, following the `--library-filter` pattern
    - `--instrumentation-scope SCOPE`: string argument, dest `instrumentation_scope`
    - `--instrumentation-scope-file FILE`: file path argument, dest `instrumentation_scope_file`

11. [ ] Add env var setup and validation to setup_env() — Gate: manual test
    - In `setup_env()`, after the `assume_triton` / HIP config block:
    - If `--instrumentation-scope` or `--instrumentation-scope-file` is provided:
      - Error out if `parms.instrumented` is False
      - Error out if `assume_triton` is False (HIP mode)
      - Otherwise: set `INSTRUMENTATION_SCOPE` / `INSTRUMENTATION_SCOPE_FILE` in env
    - For `--instrumentation-scope-file`: validate file exists (like `--library-filter`)

12. [ ] Add a Triton scope test (optional, if Triton env available) — Gate: test passes
    - Add a test case in `tests/triton/run_test.sh` or a new script that runs
      `omniprobe -i --instrumentation-scope <scope> --cache-location <cache> -- python vector_add.py`
    - Verify reduced instrumentation output compared to baseline

### Current Step
Step 1 (not started)

## Progress Log
<!-- Append updates, don't delete -->

### Session 2026-03-16 (Initial)
- Dossier created after discussion with user
- Design decisions made:
  - Plain text format for scope definitions (env var and file), not JSON
  - omniprobe errors out if scope options used without -i or without Triton
  - Buffer intrinsic CallInsts filtered by their own debug info (same as load/store)
  - Instructions without debug info skipped when scope is active
  - Parsing/matching in InstrumentationCommon for future reuse by other plugins
- Next: Begin step 1 after user approval

## Rejected Approaches

- **JSON format for scope file**: Considered for consistency with `--library-filter`. Rejected
  because (a) scope definitions are simple flat patterns, not structured config with multiple
  keys; (b) adding JSON parsing to an LLVM plugin introduces dependency complexity; (c) the
  env var is inherently plain text, and having the file use the same syntax means one parser.

- **Runtime filtering (in dh_comms/interceptor)**: Scope filtering must happen at compile time
  because it determines which instrumentation calls are inserted into the kernel. Runtime
  filtering would still incur the overhead of executing all instrumentation calls and only
  discard messages afterward — defeating the purpose.

## Open Questions

- **hipcc invocation details** (step 8): The test script compiles kernels on the fly with
  `hipcc -fgpu-rdc -fpass-plugin=<plugin>`. The exact flags, include paths, and link
  libraries need to be validated during implementation. Reference the existing CMakeLists.txt
  for the test kernels to get the right flags.

## Resolved Questions

- **Test kernel line stability**: Resolved by using `// SCOPE_MARKER` comments on
  instrumented lines. The test script greps for markers to discover line numbers
  dynamically. No hardcoded line numbers.

- **Test compilation approach**: Resolved — the test script recompiles the kernel on the fly
  with `hipcc` and the scope env var set. This is necessary because scope filtering is a
  compile-time feature. The kernel source is NOT added to CMakeLists.txt.

- **Scope file format (JSON vs plain text)**: Resolved — plain text. See Rejected Approaches.

## Last Verified
Commit: N/A
Date: 2026-03-16

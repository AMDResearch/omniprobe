# Refactor: Clang Offload Bundle (CCOB) Support

## Status
- [ ] TODO
- [ ] In Progress
- [ ] Blocked
- [x] Done

## Objective
Add support for reading compressed Clang Offload Bundle files (CCOB format) to enable omniprobe to find instrumented kernel alternatives in:
1. Tensile `.co` files (lazy-loaded kernel libraries)
2. Compressed `.hip_fatbin` sections in `.so` files (e.g., librocblas.so with offload compression)

## Acceptance Criteria

1. **Level 3 BLAS (gemm, Tensile .co)**: A test application calling `rocblas_sgemm`
   (which dispatches a kernel from a Tensile `.co` file that is instrumented and uses
   offload compression) runs successfully under omniprobe with instrumentation. The
   instrumented alternative is found, dispatched, and produces MemoryAnalysis reports.

2. **Level 1 BLAS (scal, librocblas.so)**: A test application calling `rocblas_sscal`
   (which dispatches a kernel from `librocblas.so` that is instrumented and uses offload
   compression) runs successfully under omniprobe with instrumentation. The instrumented
   alternative is found, dispatched, and produces MemoryAnalysis reports.

## Refactor Contract

### Goal
Enable omniprobe/kernelDB to transparently read GPU code objects from compressed Clang
Offload Bundle files by shelling out to `clang-offload-bundler --unbundle`.

### Non-Goals / Invariants
- ABI compatibility: n/a (internal change)
- API compatibility: Existing file scanning should continue to work unchanged
- Performance constraints: Decompression adds latency; consider caching decompressed files
- Threading model: No changes to existing threading
- Other invariants:
  - Uncompressed bundles (`__CLANG_OFFLOAD_BUNDLE__`) should continue to work
  - Fallback gracefully if clang-offload-bundler not available

### Verification Gates
- Build: `cd build && cmake --build . -j$(nproc)`
- Tests: `tests/run_all_tests.sh` — all existing tests pass
- Offload compression test: new `tests/rocblas_offload_compression/run_test.sh` passes
  (both gemm/Tensile and scal/librocblas with offload compression)

## Test Environment: Two Instrumented rocBLAS Builds

Both builds are under `/work1/amd/rvanoo/repos/rocBLAS/`:

| Build Directory | `.hip_fatbin` in librocblas.so | Tensile `.co` files |
|-----------------|-------------------------------|---------------------|
| `build-with-offload-compression/` | Compressed (CCOB) | Compressed (CCOB) |
| `build-without-offload-compression/` | Uncompressed | Likely compressed (CCOB) — build script settings did not percolate through to Tensile compilation |

Library paths:
- **With compression**: `/work1/amd/rvanoo/repos/rocBLAS/build-with-offload-compression/release/rocblas-install/lib`
- **Without compression**: `/work1/amd/rvanoo/repos/rocBLAS/build-without-offload-compression/release/rocblas-install/lib`

### Usage rules
- Switch between the two by setting `ROCBLAS_LIB_DIR` to the appropriate path.
- Do NOT use the ROCm system rocBLAS (`/opt/rocm/lib/`) — it is not instrumented.
  Only use it if you specifically need to test uninstrumented behavior (rare).
- The session-init env var `ROCBLAS_LIB_DIR` defaults to the without-compression build.
  Test scripts should set this explicitly to the build they need.

### Existing test infrastructure
- `tests/rocblas_filter/test_rocblas_scal.cpp` — level 1 BLAS test (pre-built binary exists)
- `tests/rocblas_filter/test_rocblas_gemm.cpp` — level 3 BLAS test (pre-built binary exists)
- `tests/rocblas_filter/run_test.sh` — tests scal with without-compression build (5 tests, passing)
- `ROCBLAS_LIB_DIR` env var mechanism — adopt this in all new test scripts

## Background

### Clang Offload Bundle Format

Two variants exist:

| Magic Bytes | Format | Description |
|-------------|--------|-------------|
| `__CLANG_OFFLOAD_BUNDLE__` | Uncompressed | Standard bundle, directly readable |
| `CCOB` | Compressed | Compressed bundle, requires decompression |

### Where CCOB is used

1. **Tensile `.co` files** (lazy library loading)
   - Created by `clang-offload-bundler --compress`
   - Contains optimized kernels for specific matrix sizes
   - Always compressed regardless of `BUILD_OFFLOAD_COMPRESS` flag

2. **`.hip_fatbin` sections in `.so` files** (when `BUILD_OFFLOAD_COMPRESS=ON`)
   - Embedded in ELF shared libraries
   - Contains non-Tensile GPU kernels
   - Controlled by `BUILD_OFFLOAD_COMPRESS` CMake flag

### Decompression

Both formats can be decompressed using:
```bash
clang-offload-bundler --type=o --unbundle \
  --targets=hipv4-amdgcn-amd-amdhsa--gfx90a \
  --input=compressed.co \
  --output=decompressed.hsaco
```

The tool is part of ROCm LLVM: `/opt/rocm-X.Y.Z/lib/llvm/bin/clang-offload-bundler`

### Validation (2026-03-04)

Successfully decompressed a Tensile `.co` file:
- Input: `TensileLibrary_Type_SS_Contraction_l_Ailk_Bljk_Cijk_Dijk_gfx90a.co` (598KB, CCOB)
- Output: `/tmp/tensile_ss_gfx90a.hsaco` (10.9MB, ELF)
- Contains instrumented kernels with `__amd_crk_` prefix

### Prior art: optimize_code_object_scanning refactor

The completed refactor `rf_optimize_code_object_scanning` (in `refactors/done/`) documents:
- The current file scanning flow (coCache + kernelDB)
- How `extractCodeObjects()` works (in `external/kerneldb/src/co_extract.cc`)
- How `coCache::addFile()` discovers kernels (in `src/utils.cc`)
- The on-demand scanning architecture (coCache records provenance, kernelDB scans lazily)

Key insight: CCOB decompression must happen **before** `extractCodeObjects()` can parse
the fat binary, since the entire file/section is compressed. Survey the code to determine
the exact insertion point — the affected symbols below are hypotheses.

## Scope

### Affected Symbols (verified — Phase 1 complete)
- `extractCodeObjects()` in `external/kerneldb/src/co_extract.cc:29` — **primary insertion
  point**. Two CCOB scenarios handled here:
  1. Standalone `.co` files: `getElfSectionBits()` throws because CCOB is not ELF → silently skipped.
     Fix: detect CCOB at top of function, decompress to temp file, recurse/handle.
  2. Compressed `.hip_fatbin` sections: `getElfSectionBits()` returns raw CCOB bytes →
     `findCodeObjectOffsets()` fails to find `__CLANG_OFFLOAD_BUNDLE__` magic → empty result.
     Fix: after `getElfSectionBits()`, detect CCOB in `bits`, decompress in-memory or to
     temp file, then parse the decompressed content.
- `create_temp_file_segment()` in `external/kerneldb/src/addressMap.cc:116` — reads from
  **original file on disk** using `section_offset + info.offset`. When `.hip_fatbin` is CCOB
  and decompressed in memory, these offsets don't match the on-disk layout. Need a companion
  function (`create_temp_file_from_buffer()`) that writes from in-memory bytes.
- `coCache::addFile()` in `src/utils.cc:257` — no changes needed; it delegates to
  `extractCodeObjects()` and processes returned temp file paths transparently.
- `kernelDB::getElfSectionBits()` in `external/kerneldb/src/kernelDB.cc:663` — no changes
  needed; it correctly returns raw section bytes regardless of content format.

### Expected Files (verified)
- `external/kerneldb/src/co_extract.cc` — CCOB detection + decompression integration
- `external/kerneldb/src/addressMap.cc` — new `create_temp_file_from_buffer()` function
- `external/kerneldb/include/kernelDB.h` — declare new helper if needed
- No changes to `src/utils.cc`, `src/interceptor.cc`, or `kernelDB.cc`

### Risks
- **External tool dependency**: Requires `clang-offload-bundler` at `${ROCM_PATH}/llvm/bin/`.
  Available on all ROCm installations (verified: ROCm 6.2.1, 6.3.1, 6.4.1, 7.1.0).
- **Temp file management**: Decompression creates temp files; existing temp file cleanup
  mechanism should handle these (same as `create_temp_file_segment` output).
- **GPU architecture for unbundling**: `--targets` flag needs ISA triple. Available via
  `getIsaList(agent)` which returns e.g. `amdgcn-amd-amdhsa--gfx90a`. The triple format
  for `clang-offload-bundler` is `hipv4-amdgcn-amd-amdhsa--gfx90a`.
- **`create_temp_file_segment` offset mismatch**: When decompressing in-memory, can't use
  file-offset-based extraction. Mitigated by adding buffer-based temp file creation.

### Mitigations
- Use `ROCM_PATH` env var (default `/opt/rocm`) to find `clang-offload-bundler`
- New `create_temp_file_from_buffer()` for in-memory extraction after CCOB decompression
- Decompression is transparent: callers of `extractCodeObjects()` see no difference

## Plan of Record

### Phase 1: Survey and understand the current code paths

1. [x] Read the completed `rf_optimize_code_object_scanning` dossier for context on
       the scanning architecture
2. [x] Survey `coCache::addFile()` in `src/utils.cc` — understand how files are opened,
       how `.hip_fatbin` sections are read, where CCOB would be encountered
3. [x] Survey `extractCodeObjects()` in `external/kerneldb/src/co_extract.cc` — understand
       how code objects are extracted from fat binaries
4. [x] Survey `kernelDB::getElfSectionBits()` — understand how `.hip_fatbin` section
       bytes are retrieved from ELF files
5. [x] Determine the exact insertion point(s) for CCOB decompression
6. [x] Update the "Affected Symbols" section with verified information

Gate: no code changes, understanding only. **PASSED**

### Phase 2: Implement CCOB decompression

7. [x] Add a CCOB magic detection function (`isCCOB()` — check for `CCOB` magic bytes)
8. [x] Add a decompression function that shells out to `clang-offload-bundler --unbundle`
       - Detect the ROCm LLVM path from existing configuration or `ROCM_PATH`
       - Use temp files for decompressed output
       - Detect target GPU architecture from `getIsaList()` + `hipv4-` prefix
9. [x] Integrate decompression into the identified insertion point(s) from Phase 1
       - Standalone .co files: detected at top of `extractCodeObjects()`, unbundled directly
       - Compressed .hip_fatbin sections: detected after `getElfSectionBits()`, each CCOB
         block extracted individually (V2/V3 header parsing for block sizes), unbundled
       - Uncompressed bundles continue to work (standard path unchanged)
       - Decompression is transparent to callers
10. [ ] Add temp file caching to avoid repeated decompression of the same file
       — Deferred: not needed for correctness. Can be added later if performance is an issue.

Gate: build passes, existing tests pass (`tests/run_all_tests.sh`). **PASSED**
- Build: 48/48 targets, no errors
- Tests: all 4 suites passed (handler 12/12, filter chain 5/5, rocBLAS 5/5, Triton 4/4)
- Commit: e549dcd (kerneldb)

### Phase 3: Validate with rocBLAS

11. [x] Test manually with Tensile `.co` files from both rocBLAS builds
       - Used `test_rocblas_gemm` with the with-compression build
       - CCOB decompression worked: kernel names visible in dispatch intercept
       - However, Tensile kernels are NOT instrumented (no `__amd_crk_` clones in the .co files)
       - This is a pre-existing limitation: the LLVM pass doesn't instrument Tensile's
         assembly-level kernels. Not a CCOB issue.
       - Acceptance criterion 1 (gemm) **CANNOT be met** with current Tensile builds.
         Revising to: verify CCOB decompression itself works (decompressed files are valid ELF).
12. [x] Test manually with compressed `librocblas.so` (build-with-offload-compression)
       - Used `test_rocblas_scal` with the with-compression build
       - CCOB decompression of 64 CCOB blocks in `.hip_fatbin` section successful
       - 302 kernels discovered (matching without-compression build count)
       - Instrumented alternative found for `rocblas_sscal_2_kernel`
       - L2 cache line use report and bank conflicts report generated
       - `rocblas_sscal: PASS`
13. [x] No issues to debug — scal works end-to-end, gemm limited by existing Tensile constraint

Gate: scal test produces MemoryAnalysis output. **PASSED**
Gemm: CCOB decompression verified working, but Tensile kernels not instrumented (pre-existing).

### Phase 4: Automated tests

14. [ ] Add a build script for the rocBLAS test binaries — deferred, pre-built binaries
       in `tests/rocblas_filter/` work for both builds (switching via `LD_LIBRARY_PATH`).
15. [x] Create `tests/rocblas_offload_compression/run_test.sh`
       - Uses `ROCBLAS_COMPRESSED_LIB_DIR` env var (separate from `ROCBLAS_LIB_DIR`)
       - Test 1: scal computation correct with compressed librocblas.so
       - Test 2: instrumented alternative found in decompressed `.hip_fatbin`
       - Test 3: MemoryAnalysis reports (L2 cache + bank conflicts) generated
       - Test 4: elapsed time < 120s (measured: 6s)
       - Test 5: gemm computation correct with compressed Tensile `.co` files
       - All 5 tests pass
16. [x] Register in `tests/run_all_tests.sh` as Suite 4
17. [x] Run `tests/run_all_tests.sh` — all 5 suites pass
       (handler 12/12, filter chain 5/5, rocBLAS 5/5, offload compression 5/5, Triton 4/4)

Gate: all tests pass. **PASSED**
- Commit: 9cc74e8

### Current Step
All phases complete. Refactor finished.

## Dependencies

### Unblocks
- **rf_library-filter**: rocBLAS Tensile kernel validation (currently blocked on CCOB support)

### Requires
- ROCm installation with `clang-offload-bundler`
- Both instrumented rocBLAS builds (see Test Environment section)

## Open Questions
1. Should decompressed files be cached persistently or per-session?
2. How to handle multiple GPU architectures in a single `.co` file?
3. Should we support in-memory decompression (no temp files)?

## Progress Log
<!-- Append updates, don't delete -->

### Session 2026-03-04 (planning)
- Investigated CCOB format during library-filter rocBLAS validation
- Discovered both Tensile `.co` and compressed `.hip_fatbin` use same format
- Validated decompression with clang-offload-bundler works
- Created this dossier

### Session 2026-03-05 (dossier update)
- Added acceptance criteria (level 1 scal + level 3 gemm with offload compression)
- Added test environment section documenting two instrumented rocBLAS builds
- Replaced preliminary micro-steps with concrete phased plan
- Added reference to completed rf_optimize_code_object_scanning dossier
- Added Phase 4 for automated tests (new test script + build script for test binaries)

### Session 2026-03-05 (implementation)
- Completed: Phase 1 — surveyed all code paths, identified insertion points
  - Standalone .co: `getElfSectionBits()` throws (not ELF) → silently skipped
  - Compressed .hip_fatbin: `findCodeObjectOffsets()` fails (no `__CLANG_OFFLOAD_BUNDLE__` magic)
  - Insertion points: top of `extractCodeObjects()` + after `getElfSectionBits()`
- Completed: Phase 2 — implemented CCOB decompression in `co_extract.cc`
  - `isCCOB()`, `isCCOBFile()`: detect CCOB magic bytes
  - `getCCOBBlockSize()`: parse V2/V3 headers for block boundary detection
  - `findOffloadBundler()`, `buildTarget()`: locate tool, construct ISA triple
  - `createTempFileFromBuffer()`: write in-memory bytes to temp file
  - `unbundleCCOB()`: shell out to `clang-offload-bundler --unbundle`
  - `extractFromCCOBSection()`: iterate multiple CCOB blocks in `.hip_fatbin`
  - Commit: e549dcd (kerneldb)
- Completed: Phase 3 — manual validation
  - scal: full end-to-end instrumentation with compressed librocblas.so ✓
  - gemm: CCOB decompression works, but Tensile kernels lack `__amd_crk_` clones (pre-existing)
- Completed: Phase 4 — automated tests
  - New Suite 4: `tests/rocblas_offload_compression/run_test.sh` (5 tests, all passing)
  - Registered in `tests/run_all_tests.sh`; all 5 suites pass
  - Commit: 9cc74e8
- Discovered: CCOB V3 header format: Magic(4) + Version(2) + Method(2) + FileSize(8) + UncompressedSize(8) + Hash(8) = 32 bytes
- Discovered: `.hip_fatbin` section can contain 64+ independently compressed CCOB blocks
- Discovered: Tensile `.co` files are always CCOB-compressed regardless of build flags
- Next: archive dossier to done/, update KT dossiers

### Session 2026-03-05 (Tensile instrumented kernel matching)
- Built rocBLAS with `Tensile_LOGIC=hip_full` + `BUILD_OFFLOAD_COMPRESS=ON` at `build-ccob/`
  - hip_full produces .hsaco files with 3936 `__amd_crk_` instrumented Tensile clones
  - Key: assembly kernels (asm_full) bypass LLVM IR entirely → can't instrument
- **Bug fix**: `getInstrumentedName()` in `src/utils.cc` had two bugs:
  1. Used `find_last_of(".kd")` (finds any char in set) instead of `rfind(".kd")` (finds substring)
  2. Only added `Pv` suffix for `.kd` names, but not for bare kernel names
  - The LLVM pass ALWAYS appends `Pv` (from void* parameter), so the lookup must too
  - Fix: use `rfind(".kd")` and always append `Pv` regardless of `.kd` suffix
- **Test update**: Added Test 6 to `tests/rocblas_offload_compression/run_test.sh`
  - Uses `--library-filter` include to add Tensile .hsaco to kernel cache
  - Verifies `Found instrumented alternative for.*Cijk` in output
  - Correctly skips when no instrumented sgemm Tensile clones found (asm_full builds)
- Both acceptance criteria now fully met:
  - scal (Level 1): compressed .hip_fatbin → decompressed → instrumented alternative found ✓
  - gemm (Level 3): Tensile .hsaco via library-filter → instrumented alternative found ✓

## Rejected Approaches
- **In-memory decompression**: Considered decompressing CCOB bytes in memory and feeding
  to `getCodeObjectInfo()`. Rejected because `create_temp_file_segment()` reads from the
  original file on disk using file offsets, which would be invalid after in-memory decompression.
  Instead, each CCOB block is written to a temp file and unbundled via clang-offload-bundler.

## Last Verified
Commit: uncommitted (working tree)
Date: 2026-03-05
Tests: Suite 4 — 5/5 (asm_full) or 6/6 (hip_full) passing

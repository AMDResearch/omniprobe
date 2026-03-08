# Refactor: rocBLAS Maximal Instrumentation Support

## Status
- [ ] TODO
- [ ] In Progress
- [ ] Blocked
- [x] Done

## Objective

Provide maximal instrumentation coverage for rocBLAS in omniprobe, including all
kernel types that can be instrumented: rocBLAS non-Tensile kernels, Tensile HIP
source kernels, and hipBLASLt kernels (matrix transform + TensileLite helper
kernels). Document the end-to-end build process using the sanctioned
`rocm-libraries` monorepo, and add tests for any kernel types not yet covered.

## Background

### Current state of rocBLAS instrumentation support

| Capability | Status | Test Suite | Notes |
|-----------|--------|------------|-------|
| Non-Tensile rocBLAS kernels | Working | `rocblas_filter/` | scal, gemm tests |
| Offload compression (CCOB) | Working | `rocblas_offload_compression/` | Both compressed and uncompressed |
| Tensile fallback kernels (asm_full) | Working | `rocblas_filter/` | ~87 HIP source fallback kernels |
| Tensile hip_full kernels | Working | `rocblas_offload_compression/` | ~324 HIP source kernels (optional test) |
| hipBLASLt matrix transform | Working | `hipblaslt/` | 96 kernels, standalone build |
| hipBLASLt TensileLite helpers | **Not instrumentable** | — | LLVM ICE on 564K-line generated Kernels.cpp |
| hipBLASLt + rocBLAS combined | **Working** | `rocblas_hipblaslt/` | Suite 7: scal + gemm + Tensile + reports |

### What changed (completed 2026-03-08)

1. **Build process**: Migrated from deprecated standalone repos to `rocm-libraries`
   monorepo. Full build documented in `docs/rocblas-maximal-instrumentation.md`.

2. **hipBLASLt TensileLite helpers**: **Not instrumentable** — the generated
   Kernels.cpp is 564K lines and causes an LLVM ICE in the plugin. Documented
   as a known limitation.

3. **Documentation**: Created `docs/rocblas-maximal-instrumentation.md` covering
   full monorepo build process, kernel instrumentability, and limitations.

4. **Tests**: Added Suite 7 (`tests/rocblas_hipblaslt/`) for combined rocBLAS +
   hipBLASLt instrumentation. All 43 tests across 7 suites pass.

## Kernel Instrumentability Reference

### rocBLAS kernels

| Kernel Type | Source | Compilation Path | Instrumentable? |
|------------|--------|------------------|-----------------|
| Non-Tensile (scal, axpy, etc.) | HIP C++ in librocblas.so | hipcc → .hip_fatbin | **Yes** via CMAKE_CXX_FLAGS |
| Tensile GEMM (asm_full default) | Python → Assembly | .s → .o → .co | **No** (bypasses LLVM IR) |
| Tensile GEMM (hip_full) | Python → HIP C++ | hipcc → .hsaco | **Yes** via patched SourceCommands.py |
| Tensile fallback (in asm_full) | Python → HIP C++ | hipcc → .hsaco | **Yes** via patched SourceCommands.py |

### hipBLASLt kernels

| Kernel Type | Source | Compilation Path | Instrumentable? |
|------------|--------|------------------|-----------------|
| Matrix Transform (96 kernels) | Static HIP C++ | hipcc → .hsaco | **Yes** (already done) |
| TensileLite GEMM | Python → Assembly | .s → .o → .co | **No** (bypasses LLVM IR) |
| TensileLite Helpers (BetaOnly, Conversion, Reduction) | Python → HIP C++ | hipcc → .co | **No** in practice (LLVM ICE on 564K-line Kernels.cpp) |
| Extension Ops (LayerNorm, Softmax, AMax) | Python → Assembly | .s → .o → .co | **No** (bypasses LLVM IR) |

### Why asm_full and hip_full cannot be combined

Investigated whether we can build with both `asm_full` (for performance) and
`hip_full` (for instrumentation), so omniprobe could swap assembly kernels for
instrumented HIP clones at dispatch time. **This does not work** because:

1. **Different solutions, different names**: Assembly and HIP source versions of
   conceptually similar GEMM operations are different Tensile solutions with
   different tuning parameters. At least 6 fields differ in the kernel name:
   - `ISA90a` (assembly) vs `ISA000` (HIP source)
   - `KLA` (assembly) vs `KLS` (source)
   - `MAC` vs `FMA` (different math instructions)
   - Different workgroup dimensions, tile sizes, memory model flags

2. **Zero name overlap**: A comparison of kernel symbols from `.co` (assembly) and
   `.hsaco` (HIP source) files in the same build shows zero common names.

3. **Name encoding is deterministic**: The kernel name is a deterministic encoding
   of all solution parameters including ISA, KernelLanguage, and math instruction
   type (see `SolutionStructs.py` line 1738). There is no way to make assembly
   and HIP source solutions produce the same name.

4. **omniprobe's name-based matching** (`__amd_crk_<OriginalName>Pv`) cannot
   bridge between them — the `__amd_crk_` clones in `.hsaco` files are clones
   of the HIP source kernels, not of the assembly kernels.

**Conclusion**: `hip_full` is the required mode for maximal Tensile instrumentation.
The trade-off is fewer kernel variants (~324 vs ~41,000) and potentially different
performance (compiler-generated vs hand-tuned assembly), but all kernels are
instrumentable. For profiling/analysis purposes, this is the correct choice.

### Key difference: Tensile vs TensileLite

- **Tensile** (rocBLAS): GEMM kernels can be built as HIP source via `hip_full`,
  making ALL of them instrumentable. Trade-off: fewer variants, no hand-tuned asm.
- **TensileLite** (hipBLASLt): GEMM kernels are assembly-only (hard assertion:
  "Only assembly kernels are supported in TensileLite"). No `hip_full` equivalent.

## Monorepo Build Architecture

### Repository structure

```
rocm-libraries/
├── projects/
│   ├── hipblaslt/          ← hipBLASLt (device kernels + host library)
│   ├── rocblas/            ← rocBLAS (depends on hipBLASLt via find_package)
│   └── hipblas-common/     ← Shared headers
├── shared/
│   ├── tensile/            ← Tensile (used by rocBLAS)
│   ├── rocroller/          ← JIT kernel generator (host-side, for hipBLASLt)
│   ├── origami/            ← Performance modeling (host-side, for hipBLASLt)
│   └── mxdatagenerator/    ← Test data generator
└── cmake/                  ← Shared CMake infrastructure
```

### Build order

1. **hipBLASLt** (via superbuild preset or standalone from `projects/hipblaslt/`)
   → install to custom prefix
2. **rocBLAS** (standalone from `projects/rocblas/`, NOT supported in superbuild)
   → configure with `-Dhipblaslt_path=<custom prefix>`

### Critical constraint: rocBLAS is NOT in the superbuild

```cmake
if("rocblas" IN_LIST ROCM_LIBS_ENABLE_COMPONENTS)
    message(FATAL_ERROR "rocblas is not yet supported in the superbuild")
endif()
```

rocBLAS must always be built standalone from `projects/rocblas/`.

## Implementation Plan

### Phase 1: Validate monorepo build with instrumentation (sandbox)

**Goal**: Follow the full build process in the sandbox directory to validate it
works end-to-end before documenting it.

**Working directory**: `/work1/amd/rvanoo/repos/sandbox/rocblas_maximal_support`

#### Step 1.1: Clone rocm-libraries (sparse checkout)

```bash
cd /work1/amd/rvanoo/repos/sandbox/rocblas_maximal_support
git clone --no-checkout --filter=blob:none https://github.com/ROCm/rocm-libraries.git
cd rocm-libraries
git sparse-checkout init --cone
git sparse-checkout set \
    projects/hipblaslt projects/rocblas projects/hipblas-common \
    shared/rocroller shared/mxdatagenerator shared/origami shared/tensile \
    cmake
git checkout rocm-7.1.0
```

#### Step 1.2: Build hipBLASLt with instrumentation

Two sub-steps: build the full hipBLASLt (which produces TensileLite helper kernels
and matrix transform kernels), then install.

**Option A — superbuild preset** (simplest if it works):
```bash
cd /work1/amd/rvanoo/repos/sandbox/rocblas_maximal_support/rocm-libraries
HIPBLASLT_INSTRUMENT_PLUGIN=$OMNIPROBE_PLUGIN \
cmake --preset hipblaslt \
    -DCMAKE_INSTALL_PREFIX=$SANDBOX/hipblaslt-install \
    -DGPU_TARGETS=gfx90a
cmake --build build --parallel
cmake --install build
```

The `HIPBLASLT_INSTRUMENT_PLUGIN` env var is already supported by hipBLASLt's
TensileLite build (Component.py line 221-223) for injecting `-fpass-plugin` into
helper kernel compilation. Need to verify it also applies to matrix_transform.

**Option B — standalone from projects/hipblaslt/** (if superbuild has issues):
```bash
cd /work1/amd/rvanoo/repos/sandbox/rocblas_maximal_support/rocm-libraries/projects/hipblaslt
HIPBLASLT_INSTRUMENT_PLUGIN=$OMNIPROBE_PLUGIN \
cmake -B build -S . \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_COMPILER=/opt/rocm/bin/amdclang++ \
    -DCMAKE_PREFIX_PATH=/opt/rocm \
    -DGPU_TARGETS=gfx90a \
    -DCMAKE_INSTALL_PREFIX=$SANDBOX/hipblaslt-install
cmake --build build --parallel
cmake --install build
```

**Verification**: Check that instrumented kernels exist:
```bash
# Matrix transform
nm $SANDBOX/hipblaslt-install/lib/hipblaslt/library/hipblasltTransform.hsaco | grep __amd_crk_
# TensileLite helpers (in .co files alongside GEMM .co files)
# Need to find which .co files contain helpers vs assembly GEMM
```

**Risk**: The matrix_transform CMakeLists.txt has `instrument_flags` support via
`HIPBLASLT_INSTRUMENT_PLUGIN`, but we need to verify this env var is checked at
the right point. Also need to verify the superbuild passes it through.

**Risk**: TensileLite helper kernel .co files may need unbundling (same CCOB issue
as before). Need to check the output format.

#### Step 1.3: Build rocBLAS with instrumentation + instrumented hipBLASLt

`Tensile_LOGIC=hip_full` is required. Assembly and HIP source Tensile solutions
have fundamentally different kernel names (ISA, KernelLanguage, math instruction,
workgroup dims all differ), so omniprobe's name-based matching cannot bridge
between them. There is no way to combine asm_full (performance) with hip_full
(instrumentation) — it's one or the other. For instrumentation, `hip_full` is
the only viable choice.

```bash
cd /work1/amd/rvanoo/repos/sandbox/rocblas_maximal_support/rocm-libraries/projects/rocblas

cmake -B build/release -S . \
    -DCMAKE_TOOLCHAIN_FILE=toolchain-linux.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DROCM_PATH=/opt/rocm-7.1.0 \
    -DCMAKE_PREFIX_PATH="/opt/rocm-7.1.0;$SANDBOX/hipblaslt-install" \
    -DGPU_TARGETS=gfx90a \
    -DBUILD_WITH_HIPBLASLT=ON \
    -Dhipblaslt_path=$SANDBOX/hipblaslt-install \
    -DBUILD_OFFLOAD_COMPRESS=ON \
    -DTensile_LOGIC=hip_full \
    -DTensile_LAZY_LIBRARY_LOADING=OFF \
    -DTensile_LIBRARY_FORMAT=yaml \
    -DCMAKE_CXX_FLAGS="-fpass-plugin=$OMNIPROBE_PLUGIN -ggdb" \
    -DCMAKE_INSTALL_PREFIX=$SANDBOX/rocblas-install

# Patch Tensile SourceCommands.py (same as existing Instrumentation.md approach)
# ... (find virtualenv path, patch to add -fpass-plugin)

cmake --build build/release --parallel
cmake --install build/release
```

**Verification**:
```bash
# Non-Tensile kernels instrumented in librocblas.so
nm $SANDBOX/rocblas-install/lib/librocblas.so | grep __amd_crk_ | head
# Tensile kernels instrumented in .hsaco files
nm $SANDBOX/rocblas-install/lib/rocblas/library/Kernels.so-000-gfx90a-*.hsaco | grep __amd_crk_ | head
```

#### Step 1.4: Test with omniprobe

Run the existing test programs against the new builds:
```bash
# Test rocBLAS scal with new build
INSTRUMENTED_ROCBLAS_LIB_DIR=$SANDBOX/rocblas-install/lib \
    tests/rocblas_filter/run_test.sh

# Test hipBLASLt transform with new build
# (need to adapt — new build produces different file layout)
INSTRUMENTED_HIPBLASLT_LIB_DIR=$SANDBOX/hipblaslt-install/lib \
    tests/hipblaslt/run_test.sh
```

### Phase 2: User documentation

**Goal**: Create comprehensive documentation at `docs/rocblas-maximal-instrumentation.md`
(or similar) that covers the full build process.

**Note**: No `docs/` directory currently exists. Create it.

#### Document structure

1. **Overview**: What rocBLAS is, what kernel types exist, which can/cannot be
   instrumented, and why.

2. **Prerequisites**: ROCm version, omniprobe build, disk space, GPU target.

3. **Step 1: Clone rocm-libraries** (sparse checkout instructions).

4. **Step 2: Build hipBLASLt with instrumentation**
   - Which kernels this instruments (matrix transform + TensileLite helpers)
   - Which kernels remain uninstrumented (TensileLite GEMM assembly, ExtOps assembly)
   - Explain that there is no build-mode choice here (unlike rocBLAS/Tensile):
     all four kernel types are always built together. The `HIPBLASLT_INSTRUMENT_PLUGIN`
     env var injects `-fpass-plugin` into the HIP source compilations (matrix
     transform and helpers), while assembly compilations (GEMM, ExtOps) are
     unaffected since they bypass LLVM IR entirely. There is no equivalent of
     Tensile's `hip_full` for TensileLite.
   - Build commands
   - Verification steps

5. **Step 3: Build rocBLAS with instrumentation**
   - Configure with instrumented hipBLASLt
   - Patch Tensile for instrumentation
   - Explain why `hip_full` is required (not a choice): include the
     asm_full vs hip_full comparison table:

     | Tensile_LOGIC | Assembly kernels | HIP source kernels | Instrumentable | Performance |
     |--|--|--|--|--|
     | `asm_full` (default) | ~41,000 optimized | ~87 fallbacks | Only ~87 fallbacks | Full (hand-tuned asm) |
     | `hip_full` (required) | 0 | ~324 | All ~324 | Reduced (compiler-generated) |

     Explain that combining both is impossible because assembly and HIP source
     Tensile solutions produce fundamentally different kernel names (ISA, KernelLanguage,
     math instruction, workgroup dims all differ), so omniprobe's name-based
     matching cannot bridge between them.
   - Build commands
   - Verification steps

6. **Step 4: Run with omniprobe**
   - Setting LD_LIBRARY_PATH
   - Library filter configuration for hipBLASLt .hsaco files
   - Example commands

7. **Kernel instrumentability reference** (the tables from this dossier)

8. **Limitations**: Assembly kernels, TensileLite GEMM, ExtOps

9. **Environment variables reference**

#### Supersedes

This documentation replaces:
- `.untracked/hipblaslt-instrumentation.md` (standalone hipBLASLt build)
- `/work1/amd/rvanoo/repos/rocBLAS/Instrumentation.md` (standalone rocBLAS build)

Both of those use deprecated standalone repos.

### Phase 3: Test updates

**Goal**: Add tests for kernel types not yet covered, and a combined test.

#### Step 3.1: hipBLASLt TensileLite helper kernel test

**New test directory**: `tests/hipblaslt_helpers/`

**Test program**: A HIP program that triggers hipBLASLt TensileLite helper kernels.
The helper kernels are:
- **BetaOnly**: Pre-GEMM initialization (D = beta * C + bias). Triggered by
  Global Split-U or StreamK operations.
- **Conversion**: Post-GEMM epilogue (type conversion, activation, bias).
  Triggered when output type differs from compute type or when activation is used.
- **Reduction**: Bias gradient reduction. Training-only.

The most reliable way to trigger helpers is via a GEMM with activation or mixed
types (which forces a Conversion epilogue kernel). Need to investigate during
implementation which hipBLASLt API calls reliably dispatch helper kernels.

**Environment variable**: reuse `INSTRUMENTED_HIPBLASLT_LIB_DIR`.

**Risk**: Helper kernels may not be triggered by simple GEMM calls. May need
specific configurations (activation function, mixed precision, bias). Research
needed during implementation.

#### Step 3.2: rocBLAS + hipBLASLt combined test

**New test directory**: `tests/rocblas_hipblaslt/`

**Test program**: A program that calls rocBLAS GEMM with `ROCBLAS_USE_HIPBLASLT=1`
to force the hipBLASLt backend, triggering hipBLASLt kernels through rocBLAS.

**Tests**:
1. Computation correctness (GEMM result matches expected)
2. Instrumented alternative found (for hipBLASLt transform or helper kernel)
3. L2 cache report generated
4. Bank conflicts report generated
5. Elapsed time within bounds

**Environment variables**:
- `INSTRUMENTED_ROCBLAS_LIB_DIR`: Path to rocBLAS built with maximal instrumentation
- `INSTRUMENTED_HIPBLASLT_LIB_DIR`: Path to hipBLASLt built with instrumentation

**Library filter**: Include the hipBLASLt .hsaco files (transform + helpers) since
they are loaded via `hipModuleLoad()` and not auto-discovered.

#### Step 3.3: Update run_all_tests.sh

Add the new test suites:
```bash
# Suite 7: hipBLASLt helper kernels
run_suite "hipBLASLt helpers" "${SCRIPT_DIR}/hipblaslt_helpers/run_test.sh"

# Suite 8: rocBLAS + hipBLASLt combined
run_suite "rocBLAS + hipBLASLt combined" "${SCRIPT_DIR}/rocblas_hipblaslt/run_test.sh"
```

#### Step 3.4: Update session_init_primes.json

Add environment variables for the new builds:
```json
{
    "action": "env",
    "name": "INSTRUMENTED_ROCBLAS_LIB_DIR",
    "value": "/work1/amd/rvanoo/repos/sandbox/rocblas_maximal_support/rocblas-install/lib",
    "note": "rocBLAS with maximal instrumentation (Tensile + hipBLASLt)"
},
{
    "action": "env",
    "name": "INSTRUMENTED_HIPBLASLT_LIB_DIR",
    "value": "/work1/amd/rvanoo/repos/sandbox/rocblas_maximal_support/hipblaslt-install/lib",
    "note": "hipBLASLt with full instrumentation (transform + helpers)"
}
```

### Phase 4: KT updates

Update the following KT dossiers:
- `testing.md`: Add new test suites
- `architecture.md`: Note monorepo migration for build documentation
- This dossier: Mark phases as done

## Risks and Open Questions

### Confirmed

1. **rocBLAS superbuild not supported**: Must build rocBLAS standalone. Build order
   is hipBLASLt → install → rocBLAS with `-Dhipblaslt_path=...`.

2. **TensileLite assembly-only GEMM**: hipBLASLt's TensileLite has no `hip_full`
   mode. GEMM kernels are always assembly and cannot be instrumented.

3. **hipBLASLt .hsaco files need --library-filter**: Runtime-loaded code objects
   are not auto-discovered. `rf_unify-kernel-discovery` may fix this later.

### To investigate during implementation

4. **Superbuild `HIPBLASLT_INSTRUMENT_PLUGIN` propagation**: Does the superbuild
   preset pass this env var through to the device library build? Or do we need
   standalone build from `projects/hipblaslt/`?

5. **TensileLite helper kernel triggering**: What hipBLASLt API calls reliably
   dispatch BetaOnly/Conversion/Reduction kernels? Need to find the right test
   configuration.

6. **Helper kernel output format**: Are the helper .co files CCOB-wrapped? If so,
   do they need unbundling for `--library-filter`? Or are they loaded by hipBLASLt
   automatically?

7. **Tensile in monorepo vs standalone**: rocBLAS's `ROCBLAS_TENSILE_DIR` in the
   existing build points to `../../shared/tensile` (monorepo-relative). Need to
   verify this works from `projects/rocblas/` within the sparse checkout.

8. **rocBLAS CMake changes**: The monorepo rocBLAS may have different CMake
   options than the standalone version. Need to compare and adapt the build
   commands (e.g., `toolchain-linux.cmake` location, Tensile tag handling).

9. **Build time**: Full hipBLASLt + rocBLAS builds can take hours. Plan for this.

## Verification Gates

### Phase 1 gates

- [x] rocm-libraries sparse checkout succeeds at rocm-7.1.0
- [x] hipBLASLt builds with instrumentation from monorepo
- [x] Matrix transform .hsaco contains `__amd_crk_` symbols (960 symbols)
- [N/A] TensileLite helper .co/.hsaco files contain `__amd_crk_` symbols — **skipped**: LLVM ICE on 564K-line Kernels.cpp
- [x] rocBLAS builds with instrumented hipBLASLt
- [x] rocBLAS non-Tensile kernels have `__amd_crk_` symbols
- [x] rocBLAS Tensile kernels (hip_full) have `__amd_crk_` symbols (328 symbols)
- [x] omniprobe runs existing tests against new builds (43 tests, 7 suites, all pass)

### Phase 2 gates

- [x] Documentation is complete and covers all build steps (`docs/rocblas-maximal-instrumentation.md`)
- [x] Documentation specifies which kernels can/cannot be instrumented
- [x] Build commands in documentation are verified against actual build

### Phase 3 gates

- [N/A] hipBLASLt helper kernel test dispatches and instruments a helper kernel — **skipped**: helpers not instrumentable (Decision 10)
- [x] rocBLAS + hipBLASLt combined test dispatches and instruments hipBLASLt kernels
- [x] All new tests pass (Suite 7: 5/5)
- [x] run_all_tests.sh updated and runs clean (7 suites, 43 tests total)
- [x] New test suites skip gracefully when env vars not set

## Non-Goals / Invariants

- No changes to omniprobe core code (interceptor, handlers, etc.)
- No changes to the instrumentation plugin
- No changes to existing test suites (they must continue to work as-is)
- Not trying to instrument assembly kernels (fundamental LLVM IR limitation)
- Not building TheRock (the full ROCm super-project) — only using rocm-libraries
  for source code

## Dependencies

- ROCm 7.1.0 installed at `/opt/rocm-7.1.0`
- omniprobe built with `AMDGCNSubmitAddressMessages` plugin
- Network access for sparse-cloning `rocm-libraries`
- GPU access (gfx90a) for running tests
- Sufficient disk space in sandbox (~10 GB for builds)

## Also Load

- `testing.md` — test infrastructure conventions
- `interceptor.md` — library filter and kernel discovery
- `rf_unify-kernel-discovery.md` — related work on auto-discovery of runtime-loaded .hsaco

## Research References

- `.untracked/hipblaslt_monorepo_research.md` — detailed monorepo research
- `.untracked/hipBLASLt.md` — previous session summary
- `.untracked/hipblaslt-instrumentation.md` — current (deprecated) standalone build guide
- `/work1/amd/rvanoo/repos/rocBLAS/Instrumentation.md` — current (deprecated) standalone rocBLAS build guide

## Decisions from Planning Session (2026-03-08)

These decisions were made during the planning discussion and must be followed
during implementation.

1. **Use rocm-libraries monorepo, not standalone repos.** Both `ROCm/hipBLASLt`
   and `ROCm/rocBLAS` are officially deprecated. Even though standalone builds
   work, developers already use the monorepo, so our documentation and process
   should match.

2. **`hip_full` is required for Tensile instrumentation.** Combining `asm_full`
   (assembly kernels for performance) with `hip_full` (HIP source for
   instrumentation) is impossible because assembly and HIP source Tensile
   solutions produce fundamentally different kernel names. At least 6 fields
   differ: ISA (`90a` vs `000`), KernelLanguage (`KLA` vs `KLS`), math
   instruction (`MAC` vs `FMA`), workgroup dimensions, memory model flags, and
   tile sizes. Zero kernel name overlap exists between the two. omniprobe's
   `__amd_crk_<OriginalName>Pv` matching cannot bridge between them. The user
   documentation must include the comparison table (see Phase 2 document
   structure, Step 3) and explain why this is the case.

3. **TensileLite (hipBLASLt) has no `hip_full` equivalent.** Its GEMM kernels
   are assembly-only. Only matrix transform and helper kernels (BetaOnly,
   Conversion, Reduction) are instrumentable.

4. **Build order**: hipBLASLt first (install to custom prefix), then rocBLAS
   (with `-Dhipblaslt_path` pointing to the custom install). rocBLAS is not
   supported in the monorepo superbuild.

5. **Sandbox for validation builds**: Use
   `/work1/amd/rvanoo/repos/sandbox/rocblas_maximal_support` for cloning
   rocm-libraries and building. This directory is an exception to the workspace
   boundary guardrail.

6. **No hard-coded paths in test scripts.** Use environment variables, consistent
   with existing conventions (`INSTRUMENTED_ROCBLAS_LIB_DIR`, `TRITON_DIR`, etc.).

7. **Existing tests must not break.** The new test suites are additions, not
   replacements. Existing `rocblas_filter/`, `rocblas_offload_compression/`, and
   `hipblaslt/` test suites continue to work unchanged.

8. **hipBLASLt has no build-mode choice.** Unlike rocBLAS/Tensile (where
   `hip_full` vs `asm_full` is a deliberate decision), hipBLASLt builds all four
   kernel types together with no option to select. The TensileLite GEMM assembly
   kernels and ExtOps assembly kernels are always produced alongside the
   instrumentable matrix transform and helper kernels. The
   `HIPBLASLT_INSTRUMENT_PLUGIN` env var applies `-fpass-plugin` to the HIP
   source compilations only; assembly compilations are unaffected. The user
   documentation should contrast this with rocBLAS's `hip_full` choice to avoid
   confusion.

9. **User documentation goes in `docs/` (tracked in git).** Create a new `docs/`
   directory in the omniprobe repo. The documentation is committed and visible
   to anyone cloning the repo.

10. **If helper kernel tests can't trigger helpers, skip and document.** If no
    reliable way is found to dispatch BetaOnly/Conversion/Reduction kernels via
    the hipBLASLt API during implementation, skip the `hipblaslt_helpers/` test
    suite and document the gap. Do not block on this.

## Execution Log

### Phase 1: Validate monorepo build with instrumentation

**Session start**: 2026-03-08 06:42:52 CDT

#### Step 1.0: Baseline verification (06:42:52 - 06:44:17, 1m25s)
- Ran full test suite: all 6 suites passed (36 tests)
- Plugin verified at expected path

#### Step 1.1: Clone rocm-libraries (06:44:17 - 06:51:53, 7m36s)
- Sparse checkout at rocm-7.1.0 tag to sandbox directory
- Success

#### Step 1.2: Build hipBLASLt with instrumentation (06:51:53 - ongoing)

**Key findings**:
1. `HIPBLASLT_INSTRUMENT_PLUGIN` env var does NOT exist in monorepo (dossier was wrong).
   Custom patches needed.
2. Patched matrix_transform CMakeLists.txt with `OMNIPROBE_INSTRUMENT_PLUGIN` env var
   to inject `-fpass-plugin` into matrix_transform compilation.
3. Initially patched Component.py to inject `-fpass-plugin` into TensileLite helper
   compilation — **reverted** because:
   - With `--no-lazy-library-loading`: duplicate symbol linker errors (same .o linked twice)
   - With lazy loading enabled: TensileLite generates a 564K-line Kernels.cpp containing
     all helper kernel variants. Our plugin crashes (LLVM ICE) on this massive file.
4. **Decision**: Build TensileLite WITHOUT instrumentation. Only matrix_transform is
   instrumented. TensileLite helper instrumentation is a limitation to document.
5. Device-only build works: `-DHIPBLASLT_ENABLE_HOST=OFF -DTENSILELITE_ENABLE_HOST=OFF`
6. Requires: `-DHIPBLASLT_ENABLE_LAZY_LOAD=ON` (otherwise undefined when host disabled)
7. Python 3.12 dependencies installed: pyyaml, joblib, msgpack, simplejson, ujson,
   packaging, orjson

**Corrected dossier table** (line 64):
- TensileLite Helpers: instrumentable in theory via Component.py, but in practice the
  generated Kernels.cpp is too large for the plugin (564K lines, LLVM ICE).

**Additional fixes needed**:
8. `CMAKE_ASM_COMPILER` must be set to `amdclang++` (system `cc` doesn't support AMDGPU asm)
9. Build succeeded at 07:41:05 CDT after fixing all issues
10. Created custom hipBLASLt installation with symlinked system host library
11. Unbundled matrix_transform .hsaco: 960 instrumented symbols confirmed

**Step 1.2 completed**: 07:41:05 CDT (49m12s total for Step 1.2)

#### Step 1.3: Build rocBLAS with instrumentation (07:42:15 - 08:14:23, 32m8s)
- Configured rocBLAS from monorepo with:
  - `Tensile_LOGIC=hip_full`, `Tensile_LAZY_LIBRARY_LOADING=OFF`
  - `BUILD_WITH_HIPBLASLT=ON`, pointing to custom hipBLASLt install
  - `BUILD_OFFLOAD_COMPRESS=ON`
  - `CMAKE_CXX_FLAGS="-fpass-plugin=... -ggdb"` for non-Tensile kernels
- Patched `SourceCommands.py` in virtualenv for Tensile kernel instrumentation
- Build completed: 216MB librocblas.so with CCOB compression
- 328 instrumented Tensile kernel symbols in .hsaco files

#### Step 1.4: Test with omniprobe (08:15:02 - 08:20:33, 5m31s)
- Ran full test suite: all 7 suites passed (43 tests)
- New Suite 7 (rocBLAS + hipBLASLt combined): 5/5 passed

**Phase 1 total**: 06:42:52 - 08:20:33 (1h37m41s)

### Phase 2: User documentation (07:47:16 - 07:50:00, 2m44s)
- Created `docs/rocblas-maximal-instrumentation.md` covering full build process
- Documents all kernel types and instrumentability
- Explains why hip_full is required (includes comparison table)
- Documents TensileLite helper limitation

### Phase 3: Test updates (07:50:00 - 08:15:02, 25m2s)
- Created `tests/rocblas_hipblaslt/run_test.sh` combined test suite
- Updated `tests/run_all_tests.sh` to include Suite 7
- Updated `.claude/session_init_primes.json` with new env vars
- Skipped `hipblaslt_helpers/` test suite (Decision 10: helpers can't be instrumented)

### Phase 4: KT updates (08:20:33 - 08:25:00)
- Updated `testing.md` with Suite 7 info
- Updated this dossier: execution log, verification gates, status → Done
- Corrected hipBLASLt kernel instrumentability table (TensileLite helpers: not instrumentable in practice)

**Session total**: 06:42:52 - 08:25:00 (~1h42m)

## Created
Date: 2026-03-08

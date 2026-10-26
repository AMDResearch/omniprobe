# Instrumentation

## Responsibility

LLVM IR instrumentation plugins that clone kernels at compile time and insert instrumentation calls. The original kernel is preserved; the clone receives an extra argument for dh_comms communication.

## Key Source Files

| File | Purpose |
|------|---------|
| `src/instrumentation/AMDGCNSubmitAddressMessages.cpp` | Address message instrumentation |
| `src/instrumentation/AMDGCNSubmitBBStart.cpp` | Basic block entry tracking |
| `src/instrumentation/AMDGCNSubmitBBInterval.cpp` | Basic block timing |
| `src/instrumentation/InstrumentationCommon.cpp` | Shared instrumentation logic |
| `src/instrumentation/include/` | Headers for instrumentation plugins |
| `cmake_modules/add_instrumentation_plugins.cmake` | CMake function for building plugins |

## Key Types and Classes

N/A — LLVM pass plugins, no user-defined classes.

## Key Functions and Entry Points

| Function | Location | Purpose |
|----------|----------|---------|
| `add_instrumentation_plugins()` | `cmake_modules/add_instrumentation_plugins.cmake` | CMake function, called once per LLVM variant |

## Data Flow

1. Compile time: LLVM pass plugin loaded via `-fpass-plugin`
2. Plugin clones each kernel, creates instrumented variant with `_inst` suffix
3. Instrumented variant gets extra `void* dh_comms_descriptor` argument
4. At runtime, interceptor finds and swaps to instrumented variant

### Plugins Produced

| Plugin | Instruments | dh_comms Calls | Used By Analyzers |
|--------|-------------|----------------|-------------------|
| AMDGCNSubmitAddressMessages | Load/Store | `v_submit_address()` | AddressLogger, Heatmap, MemoryAnalysis (default) |
| AMDGCNSubmitBBStart | Basic blocks | `s_submit_wave_header()` | BasicBlockLogger, BasicBlockAnalysis |
| AMDGCNSubmitBBInterval | BB timing | `s_submit_time_interval()` | (none - available but unused) |

### Build System

See `build-system` PM unit for multi-LLVM-variant compilation details, bitcode location,
and `add_instrumentation_plugins()` usage.

### InstrumentationScope

Reads `INSTRUMENTATION_SCOPE` and `INSTRUMENTATION_SCOPE_FILE` environment variables at compile time to restrict which instructions are instrumented. Syntax: `file[:N[:M][,N[:M]...]][;...]`

### Address Space Mapping

| Address Space ID | Name |
|------------------|------|
| 0 | FLAT |
| 1 | GLOBAL |
| 3 | SHARED |
| 4 | CONSTANT |

DWARF source location is encoded in messages for correlation with source code.

## Invariants

- Plugin must match LLVM version (ROCm vs Triton builds are separate)
- Instrumented kernel suffix is always `_inst`
- dh_comms descriptor is passed as the final kernel argument
- Address space mapping: FLAT(0), GLOBAL(1), SHARED(3), CONSTANT(4)
- DWARF source location is encoded in messages

## Dependencies

- **sub-dh-comms** — device-side bitcode for message submission. Also load: `sub-dh-comms.md`

## Negative Knowledge

- This was formerly a separate submodule (`instrument-amdgpu-kernels`). It was absorbed into `src/instrumentation/` on 2026-03-24. Do NOT treat it as a submodule or look for it under `external/`.
- Default plugin is `libAMDGCNSubmitAddressMessages`. HIP mode requires manual compilation with `-fpass-plugin`; Triton mode sets `LLVM_PASS_PLUGIN_PATH` automatically.
- `libAMDGCNSubmitBBInterval-triton.so` exists but no analyzer currently uses it.

## Negative Knowledge — clone naming under internal linkage

`InstrumentationCommon.cpp:211` builds the clone name as
`"__amd_crk_" + OrigKernel->getName() + "Pv"`, appending `Pv` to the **end of the whole symbol**.
For an ordinary kernel that is fine. For an internal-linkage kernel under `-fgpu-rdc`, whose
symbol carries a compiler-generated `.intern.<hash>` suffix, it puts `Pv` *outside* the mangling
and the result is not a well-formed mangled name — `__cxa_demangle` fails on it (measured
2026-09-08). `Pv` would have to attach to the base mangling, before the suffix.

Two consequences worth carrying:

- **`.intern.<hash>` is per-translation-unit, not per-symbol**, and it changes with compile flags
  — the same source produced `26db06f5c7a9cf0b` plain and `69c48a2e06e7f383` with the
  instrumentation plugin. **No test may pin a literal hash.**
- Renaming clone symbols is not a free change: instrumented rocBLAS and hipBLASLt libraries were
  built under the current scheme, and `tests/rocblas_hipblaslt/run_test.sh:86` matches on
  `__amd_crk_Cijk`.

Tracked by `bf_intern-clone-name`.

## The AMDGPU attributor runs before this plugin, and clones inherit its conclusions

Measured 2026-10-26 on gfx90a / ROCm 7.2.0, prompted by GitHub issue #43 and PR #44.

`AMDGPUTargetMachine::registerPassBuilderCallbacks` adds `AMDGPUAttributorPass` at
`OptimizerLastEP`, registered in the `PassBuilder` constructor — i.e. **before** any plugin is
loaded. So whenever the pipeline has a target machine, the attributor runs first and marks each
kernel `amdgpu-no-*` for implicit inputs it does not use. `cloneKernelWithExtraArg` then copies
those attributes onto the instrumented clone **twice** — `copyAttributesFrom` at `:228` and again
inside `CloneFunctionInto` at `:240`. Any removal must therefore happen *after* the second call;
removing earlier has no effect.

The attributes describe the kernel *before* instrumentation, so they are stale for the clone: the
injected dh_comms calls read inputs (`workgroup id y/z`, `workitem id y/z`, the implicit-argument
pointer) that the original did not. Re-running the attributor does not help — it treats existing
`amdgpu-no-*` attributes as known facts.

**This is a HIP-path property, not only a Triton one.** ROCm's own device compile (including
`-fgpu-rdc`) also runs the attributor ahead of `-fpass-plugin` passes. Measured on the in-repo
heatmap test: the instrumented clone carries 17 `amdgpu-no-*` attributes and its final kernel
descriptor has `.amdhsa_system_sgpr_workgroup_id_y 0` / `_z 0`, while `s_submit_message` reads
those intrinsics.

**Calibrate the impact carefully — a first analysis overstated it.** The backend does not emit a
read of an unallocated register; it **constant-folds** the disabled intrinsics. Evidence: the
clone body is 1181 instructions as-is versus 1980 with the attributes removed, the difference
being the y/z-dependent computation eliminated outright. Consequences:

- **1-D launches:** folding y/z to 0 is the *correct* answer, so no defect in practice. This
  covers the entire in-repo suite, which is why it is green either way.
- **2-D / 3-D launches of a kernel that does not itself read `blockIdx.y/z`:** dh_comms'
  sub-buffer index is `(wg_x + wg_y*gx + wg_z*gx*gy) % N`, so folding **collapses the y and z
  dimensions** — workgroups differing only in y/z share a sub-buffer. Wrong and deterministic,
  not undefined.
- **Unverified:** whether that collapse is observable in handler output. dh_comms sub-buffer
  semantics were not traced.

Fix proposed upstream as PR #44 (19 lines, `InstrumentationCommon.cpp`): drop all `amdgpu-no-*`
from the clone after `CloneFunctionInto`. Blanket removal rather than a targeted list is
deliberate — a list goes stale silently the next time dh_comms reads something new. Verified
locally 2026-10-26: compiles `-Werror` against both ROCm's and Triton's LLVM, flips
`workgroup_id_y/z` to 1, leaves uninstrumented originals untouched, full suite 11/11.

**One change covers six plugins.** `cloneKernelWithExtraArg` is shared by all three passes
(`AddressMessages`, `BBStart`, `BBInterval`) and `cmake_modules/add_instrumentation_plugins.cmake:92`
builds each in both `-rocm` and `-triton` flavours from the same objects.

## Negative Knowledge — `validateAMDGPUTarget` is an exact string match

`InstrumentationCommon.cpp:150` tests `TripleStr == "amdgcn-amd-amdhsa"`. Newer LLVM (as carried
by Triton `main` / v3.8.0) emits the normalized form `amdgpu9.50-amd-amdhsa`, which fails that
test — so every pass **skips every kernel, silently and with exit 0**. It still compiles; nothing
errors. `M.getTargetTriple().isAMDGCN()` is the suggested replacement.

Reported as item 2 of GitHub issue #43 and **not** fixed by PR #44. This is the archetype of the
risk in a Triton/LLVM bump: the dangerous breakage is semantic, not a compile error, and CI
(`build.yml`, build-only, `ubuntu-latest`, no GPU, no test invocation) cannot see it at all.

## Open Questions

None.

## Last Verified

2026-04-27 (trimmed by pm-restructure; build system section moved to build-system)
2026-09-08 (clone-name construction under internal linkage; measured, not re-read)
2026-10-26 (AMDGPU attributor ordering and clone attribute inheritance, measured; validateAMDGPUTarget triple fragility)

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

**Fixed by PR #44, merged 2026-10-27 as `b12d7f0`** (author Lixun Zhang; 19 lines in
`InstrumentationCommon.cpp`): drop all `amdgpu-no-*` from the clone after `CloneFunctionInto`.
Blanket removal rather than a targeted list is deliberate — a list goes stale silently the next
time dh_comms reads something new. Verified on Triton v3.8.0 before merge: compiles `-Werror`
against ROCm's and Triton's LLVM, full suite 11/11.

Measured effect in the **real linked `-fgpu-rdc` build** (heatmap test, gfx90a, patched vs
unpatched plugin side by side):

| kernel | `workgroup_id_y/z` | `vgpr_workitem_id` | `kernarg_size` |
|---|---|---|---|
| instrumented clone, before | 0 / 0 | 2 | 280 |
| instrumented clone, after | **1 / 1** | 2 | 280 |
| original kernel, both | 0 / 0 | 0 | 272 |

**`vgpr_workitem_id` is NOT changed by #44** — a `0 → 2` claim circulated for a day and was
wrong. It came from running `llc` over *pre-link* single-TU IR, the configuration already
withdrawn for the "uninitialised `s13`/`s14`" claim: there `v_submit_address` is an uninlined
callee and the numbers differ. Measure descriptors from the final linked `.lto.s` (the stage
carrying `__amd_crk_*`), never from pre-link IR. The only `0` in the real build is the
*original* kernel's.

**On the Triton path #44 is currently a no-op.** Triton v3.8.0 still drops the target machine
whenever a pass plugin is loaded (`python/src/llvm.cc:751`, `!arch.empty() && pluginFile.empty()`),
so the attributor never runs there. It starts mattering when triton-lang/triton#10849 (keep the
target machine) lands — which is what #43 was filed about.

**One change covers six plugins.** `cloneKernelWithExtraArg` is shared by all three passes
(`AddressMessages`, `BBStart`, `BBInterval`) and `cmake_modules/add_instrumentation_plugins.cmake:92`
builds each in both `-rocm` and `-triton` flavours from the same objects.

## `validateAMDGPUTarget` accepts subarch-aware triples (fixed 2026-10-27, `e6db747`)

Was an exact string match, `TripleStr == "amdgcn-amd-amdhsa"`. Now
`llvm::Triple(TripleStr).isAMDGCN()`. Reported as **item 1** of zhanglx13's 2026-09-26 comment
on issue #43; #43 closed when #44 merged, after this fix landed.

Why the old check would have broken, and when — the record of this was wrong for a day:

- **Triton v3.8.0 is unaffected on every architecture.** It hardcodes
  `const char *const amdTargetTriple = "amdgcn-amd-amdhsa";` (`third_party/amd/python/triton_amd.cc:45`)
  and never consults the arch. Measured on gfx90a: `device function module found for amdgcn-amd-amdhsa`.
- **triton-lang/triton#11532** ("[AMD] Use subarchitecture-aware target triples", on `main`
  2026-09-01, after v3.8.0) builds `Triple(Triple::amdgpu, subArch, AMD, AMDHSA)` for **every**
  arch — gfx950 → `amdgpu9.50-amd-amdhsa`, gfx90a its own subarch form. An exact match would skip
  every Triton kernel on every GPU, silently, from the next Triton bump on.
- **Why `isAMDGCN()` survives it:** LLVM renamed the enum `Triple::amdgcn` → `Triple::amdgpu`
  (present at Triton `main`'s pin `18f9e623`, absent at v3.8.0's `5f07f818`) and updated
  `isAMDGCN()` to test the new one; that LLVM also parses the spelling `"amdgcn"` as a legacy
  name for `amdgpu`. Each plugin variant compiles against its own LLVM's headers, so the method
  means "is an AMD GPU target" in both. The string is parsed rather than calling
  `M.getTargetTriple().isAMDGCN()` to keep compatibility with LLVMs whose `getTargetTriple()`
  returns `std::string` (none of the three we build against today do).
- **The negative check matters as much as the positive one.** `-fpass-plugin` runs on the host
  compile too; verified the x86_64 host module is still rejected.

Not tested end to end against Triton `main` (needs a source build of it); zhanglx13 reports the
same check working there. The general lesson stands: the dangerous breakage in a Triton/LLVM bump
is semantic, not a compile error, and CI (`build.yml`, build-only, no GPU) cannot see it.

## Open Questions

None.

## Last Verified

2026-04-27 (trimmed by pm-restructure; build system section moved to build-system)
2026-09-08 (clone-name construction under internal linkage; measured, not re-read)
2026-10-26 (AMDGPU attributor ordering and clone attribute inheritance, measured; validateAMDGPUTarget triple fragility)
2026-10-27 (#44 merged, descriptor table re-measured in the linked build — workitem_id claim corrected; validateAMDGPUTarget fixed, triple history corrected from Triton source)

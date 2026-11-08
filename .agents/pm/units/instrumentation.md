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
| AMDGCNSubmitBBInterval | BB timing (experimental) | `s_submit_time_interval()` | no analyzer; default time-interval handler, PythonHandler `handleTimeMessage` |

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
| 5 | PRIVATE (scratch) |

Since 2026-11-08 a **flat pointer is classified at run time** — see § Flat-pointer accesses.
The space ID sent is then the run-time one; 0 means a wave whose lanes mix spaces.

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
- `libAMDGCNSubmitBBInterval-*.so` has no analyzer, deliberately (see § BBInterval). Do not build
  a per-block timing analyzer on it without new evidence.

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

Tracked by `bf_intern-clone-name` — **now done** (2026-11-08). The fix is on the lookup side
(`3e31ee8`, see `interceptor`); **clones are deliberately NOT renamed**, so prebuilt instrumented
rocBLAS/hipBLASLt keep working.

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

## Plugin robustness (2026-11-08)

- **Missing or unreadable device bitcode is fatal** (`report_fatal_error`): hipcc exits 1, a
  Triton JIT compile exits 1 (`5d9266b` and its follow-up fix).
- `__hip_cuid_*` globals in the dh_comms bitcode are given **internal linkage before linking**,
  which fixes "duplicate symbol" in multi-file `-fgpu-rdc` links (`f3b9b8f`).
- `-fgpu-rdc` is **optional** for instrumentation; two-file non-RDC applications work.
- For Triton modules the plugin sees **no `target-cpu`** ("target unknown") and falls back to
  the cdna2 bitcode. Relevant to `rf_exact-arch-bitcode`.
- BBStart attributes a block to its first instruction with a line, walked through `inlinedAt`
  (see `handler-pipeline` § BasicBlockAnalysis semantics).

## Flat-pointer accesses are classified at run time (2026-11-08, `e807927`)

In `AMDGCNSubmitAddressMessages.cpp` (`classifyFlatAddressSpace`): for a pointer whose address
space is still flat after `stripPointerCasts()`, the plugin emits per lane `llvm.amdgcn.is.shared`
/ `llvm.amdgcn.is.private`, made wave-uniform with `llvm.amdgcn.ballot.i64` compared against
`ballot(true)` (the active lanes), because `v_submit_address` sends one space per wave message.
All active lanes shared → 3, all private → 5, none of either → 1, **mixed → 0** (stays
unanalyzed). If the accessed pointer itself is non-flat (a cast from flat), its own space is used.

- **No address conversion:** the static LDS path already submits the *flat* address of an LDS
  location (aperture base + offset, e.g. `0x1000000000000`), so a flat pointer into LDS is
  already in the form the bank-conflict analysis expects.
- **Non-flat accesses emit exactly the code they did before** (measured: `bank_conflict_test.cpp`
  `-O3`, identical device instruction stream, 8378 instructions).
- Done in the plugin, not in dh_comms's `v_submit_address`, because dh_comms is a submodule this
  project could not push to (`pm-decisions`). Both `-rocm` and `-triton` variants get it.
- Effect: `-O0` builds and accesses through pointers loaded from memory get the same
  MemoryAnalysis findings as optimized, statically typed ones (suite 21). Untested on
  gfx942/gfx950 (generic AMDGPU intrinsics) and not exercised by the Triton suite.

## BBInterval (2026-11-08: `dc9a6fe`, `ccb109f`; verdict in `iv_bb-interval-timing-spike`)

- **One alloca in the entry block, reused by every block** (`dc9a6fe`). It used to `alloca` its
  `[2 x i64]` buffer in every block; outside the entry block that is a *dynamic* alloca
  (`.uses_dynamic_stack: true`), the stack grew 16 B/lane per block execution, and ROCm 7.2
  codegen stored with a wave-scaled `soffset` but reloaded with an unscaled per-lane `offen`
  offset [inf: LLVM codegen bug]. Symptoms: every non-entry interval read start=stop=0, and a
  loop of >= 17 iterations faulted ("illegal memory access"). The entry alloca must be skipped
  when picking the entry block's first instruction, or the module fails verification.
- **Pinning** (`ccb109f`): `llvm.amdgcn.sched.barrier(0)` after the start clock and before the
  stop clock, plus an empty side-effecting inline asm (`"v"` constraint) use, before the stop
  clock, of every value the block defines for later blocks or PHIs (ints widened/split to 32/64
  bits, pointers via ptrtoint, floats bitcast, vectors per element). Without it codegen moved the
  block's work past the stop clock and hoisted loads above the start clock (~4–12 ticks per
  interval regardless of work). With it a loop body reads 60 ticks/iteration, steady at 10 / 1000
  / 100000 iterations.
- **Verdict: experimental, not a per-block timing tool** (supervisor ruling, outcome (c)). On
  PENNANT the numbers measure the instrumentation more than the code: each block inlines ~1000
  instructions of submit code (cold instruction fetch; floor ~520 ticks per block), barrier/atomic
  waits are inflated by other waves' instrumentation (gpuMain5: ~86% of all ticks vs 16.8% of
  plain kernel time), `s_memtime` has no reliable tick→time conversion [inf], and intervals from
  concurrent waves overlap (a latency, not exclusive cost). Top-block ranking within a kernel was
  stable across runs; lower ranks swapped. Use BasicBlockAnalysis counts instead.
- Block line attribution uses the block's first instruction **without** following `inlinedAt`
  (often a header line) — unlike BBStart.

## Device bitcode selection (2026-11-08, `rf_exact-arch-bitcode`, PR #38)

`getBitcodePath()` (`src/instrumentation/InstrumentationCommon.cpp`) takes the architecture from
the `target-cpu` module flag, else a function's `target-cpu`, else the **triple** (Triton modules
carry no `target-cpu`; since Triton v3.9.0 the triple names the processor: `amdgpu9.0a` -> gfx90a,
`amdgpu9.50` -> gfx950; family-level names like `amdgpu9.4` give nothing). It links
`dh_comms_dev_<arch>_coN.bc` if that file exists and the arch is in `IdentifiedByDhComms`
(gfx906/908/90a/940/941/942/950); otherwise the legacy bucket (cdna3 for gfx94x, cdna2 else) with a
warning naming the missing file. **The allowlist matters:** dh_comms device code for an arch it
does not list compiles without error (its `#error` guard is dead, see `sub-dh-comms`) and reports
`gcnarch::unsupported`, which MemoryAnalysis skips silently. Adding an arch = dh_comms enum +
`data_headers_dev.h` branch + this list + `IDENTIFIED` in `tests/test_bitcode_selection.sh`.
Per-arch files exist only for `CMAKE_HIP_ARCHITECTURES`. Suite 25 checks all of this, compile-only.

## Open Questions

None.

## Last Verified

2026-04-27 (trimmed by pm-restructure; build system section moved to build-system)
2026-09-08 (clone-name construction under internal linkage; measured, not re-read)
2026-10-26 (AMDGPU attributor ordering and clone attribute inheritance, measured; validateAMDGPUTarget triple fragility)
2026-10-27 (#44 merged, descriptor table re-measured in the linked build — workitem_id claim corrected; validateAMDGPUTarget fixed, triple history corrected from Triton source)
2026-11-08 (bitcode-missing fatal, __hip_cuid_ internalization, Triton target-unknown fallback, clone-naming bug closed without renaming; attributor and triple sections not re-verified, resting on 2026-10-27)
2026-11-08 (second session: run-time flat-pointer classification; BBInterval entry alloca, pinning and the (c) verdict; verified against e807927, dc9a6fe, ccb109f and grep of AMDGCNSubmitBBInterval.cpp at 22c4d95, numbers from the ft_flat-address-classification and iv_bb-interval-timing-spike packets, not re-measured; triple and attributor sections not re-read)
- 2026-11-08 (third session): bitcode selection section; verified on gfx90a and gfx950 (MI350).

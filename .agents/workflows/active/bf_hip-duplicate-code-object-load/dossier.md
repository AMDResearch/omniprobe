# Workflow Dossier: bf_hip-duplicate-code-object-load

## Metadata

- Workflow ID: bf_hip-duplicate-code-object-load
- Workflow Type: bugfix
- Lifecycle State: active
- Owner / Current Executor: unassigned
- Intended Write Scope: see the `write-scope` block below
- Dependencies On Other Active Workflows: **overlaps `rf_lazy-kerneldb-loading`** (both write
  `src/interceptor.cc`; see Dependencies). Also touches the same file as
  `rf_rename-logduration-to-omniprobe`, whose scope is broad enough to collide with most packets.
- Base Commit: 74c6ed2dded669fe797dff5234dee4a7d1eef8ab

```write-scope
src/utils.cc
inc/utils.h
src/interceptor.cc
tests/
docs/
```

## Objective

For a HIP application, Omniprobe loads a **second, private copy** of every code object the
process already has mapped. The private copy gets its own, never-initialised `__constant__`
segment. Kernels dispatched out of it read all `__device__`/`__constant__` globals as **zero**,
silently producing plausible-looking but empty analysis results.

Make Omniprobe dispatch instrumented clones out of the **application's own** executable for HIP
fat binaries, so `__constant__` state written by `hipMemcpyToSymbol` is visible to the clone.
Preserve the `coCache::addFile` path for Triton, which genuinely needs it.

## Background / Context

Found on 2026-09-01 while profiling PENNANT (a Los Alamos unstructured-mesh hydro proxy app) on
MI350X / `gfx950` / ROCm 7.2.0 with `-a MemoryAnalysis`. Full external write-up:
`pennant-amp-sidecar/pennant_omniprobe.md` §3.3 (see References). Every source anchor below was
re-verified against this repository at `74c6ed2` on 2026-09-08; one anchor in the original
write-up was wrong and is corrected here (`findAlternative` is at `src/utils.cc:706`, not `:945`).

### The two copies

- **The application's own executable.** The instrumentation pass emits each clone next to its
  original *in the same code object*, so the fat binary carries both, sharing the one
  `__constant__` segment HIP initialises. Confirmed in PENNANT's binary symbol table:
  `_ZL8gpuMain5dPKdS0_` and `__amd_crk__ZL8gpuMain5dPKdS0_Pv`, plus both `.kd` descriptors, are
  present for every kernel. Dispatching the clone out of this copy is correct by construction.
- **Omniprobe's private executable.** `coCache::addFile` (`src/utils.cc:503`) calls
  `extractCodeObjects` (`src/utils.cc:511` → `external/kerneldb/src/co_extract.cc:181`), which
  writes every code object in the `.hip_fatbin` to a temp file as a raw byte-range copy — no
  filtering, no transformation — and `addFile` then loads them as a separate HSA executable
  (`hsa_executable_create_alt` → `hsa_executable_load_agent_code_object` → `hsa_executable_freeze`,
  `src/utils.cc:511–556`). Byte-for-byte identical device code, but with its own `.data` /
  `__constant__` allocation that nothing ever initialises.

Not limited to the main binary: the PENNANT run logged **95** `Adding` lines, one per
`.hip_fatbin`-carrying object in the process.

### Why the wrong copy wins

`findInstrumentedAlternative` (`src/utils.cc:736`) → `findAlternative` (`src/utils.cc:706`)
resolves every clone through one table, `lookup_map_` (`inc/utils.h:184`). Two paths write it:

| writer | when | filtered by `-k`? | symbols come from |
|---|---|---|---|
| `coCache::addFile`, insert at `src/utils.cc:640–644` | startup | **yes** — regex at `src/utils.cc:610–624`, bare `continue` on no-match, *before* the insert | Omniprobe's **private** executable → `__constant__` zeroed |
| `coCache::registerRuntimeKernel` (`src/utils.cc:206`, called from `src/interceptor.cc:964`) | first dispatch | **no** | the **application's own** executable → `__constant__` correct |

`registerRuntimeKernel` returns early when the name is already present
(`src/utils.cc:213–214`, `// Already registered`), so the **first writer wins — and startup
beats first dispatch**. The comment above it states the intent outright: *"Register
runtime-discovered kernels in the cache so that findInstrumentedAlternative() can find them
without --library-filter."*

This reads as Triton machinery reused for HIP rather than a deliberate two-executable design.
The comment above `getSharedLibraries` (`src/utils.cc:1023`) draws the distinction itself.
`coCache::addFile` dates from 2024-08-23 (inotify-watching a Triton JIT cache);
`registerRuntimeKernel` from 2026-03-23 (`rf_unify-kernel-discovery`, "Unify kernel discovery
for runtime-loaded code objects"). Nineteen months apart, and the newer HIP-appropriate path was
**added alongside** the older one rather than displacing it — that packet's run-log records
*"augmented coCache with registerRuntimeKernel() … instead of replacing it"* and *"Deferred full
KernelRegistry class (dossier Phase 1)."* This defect lives in that deferral.

### Observed symptoms

Minimal reproducer (one kernel; a scalar and a pointer as kernargs, plus a `__constant__ double *`
and a `__constant__ int` set via `hipMemcpyToSymbol`) — kept at
`pennant-amp-sidecar/.untracked/omniprobe-2026-09-01/argprobe_g.hip`:

```
plain run:            clone saw: cdata=0x7f2e05e00000 cscalar=12345 scale=2.5  → PASS
under omniprobe -i:   clone saw: cdata=0x0            cscalar=0     scale=2.5
                      → kernargs OK, __constant__ CORRUPT
```

Kernel arguments arrive intact; `__device__`/`__constant__` globals arrive zeroed. Identical with
and without `-fgpu-rdc`. Direct confirmation in PENNANT: an `AddressLogger` trace shows the broken
kernel loading its guard variable from `__constant__` base `0x7fd925c1102c` while every other
kernel uses `0x7fd92441102c` — two executables, two constant segments.

PENNANT is maximally exposed because all device array pointers and mesh sizes are file-scope
`__constant__`. Zeroed, `numz == 0`, so every kernel takes its `if (z >= numz) return;` guard.
All three symptoms were observed:

- exactly one recorded access per kernel — the `__constant__` guard load itself, all 64 lanes at
  the same address;
- final energy equal to the *initial* energy, kinetic exactly 0 — the state never advanced;
- `Memory access fault … on address 0xfffffffff000` on some runs.

**The failure is silent.** Nothing in the output says the results are empty because the constants
were zero. That is what makes this worth fixing rather than documenting.

### `-k` is a workaround, and its behaviour is close to inverted

`-k <regex>` is documented as "only instrument kernels matching this regex". Because the filter
gates only the `addFile` writer, it actually selects **which copy a kernel's clone is taken
from**: kernels that **match** `-k` are served from the broken private copy; kernels that do
**not** match are served, still instrumented, from the application's own copy. Every kernel with
an `__amd_crk_…Pv` symbol is swapped either way, so `Found instrumented alternative` prints for
all of them regardless of the filter.

The regex must also name a kernel that is **actually dispatched**, because `kernel_co_map_`
(written at `src/utils.cc:645`, behind the same filter) feeds `getCodeObjectRef`
(`src/utils.cc:487`) at `src/interceptor.cc:806`, and only a dispatch reaching
`kdb->scanCodeObject` (`src/interceptor.cc:807`) primes the kernel database for DWARF
correlation — for *every* kernel in the object, since `scanCodeObject` takes a file.

Measured (PENNANT, `sedovsmall`, `cstop 1`):

| `-k` argument | result |
|---|---|
| *(omitted)* | no usable data, wrong physics, intermittent memory fault |
| `"setBoundary"` | **works** — correct physics, full data for the other ten kernels; 3/3 identical at 1 rank, and at 2 ranks |
| `"gpuMain2"` | data for other kernels, physics wrong (`gpuMain2` is essential) |
| `"NOSUCHKERNEL"`, `"__amd_rocclr"`, `"preHaloExchange"` | correct physics, almost no accesses — nothing matched dispatches, so kernelDB stayed empty and every message was dropped |
| `"gpuMain5"` at 2 ranks | exit code 1, no accesses — **unexplained** |

So the workaround requires a kernel that is dispatched *and* whose loss does not matter; it is
sacrificed precisely because being sacrificed is what primes the kernel database. PENNANT had
exactly one such kernel. Most applications will not.

## Contract

Fix the root cause — the duplicate load and the first-writer race — not the `-k` symptom. The
Triton path must keep working: for a JIT cache the application has never loaded the instrumented
kernels, so `coCache::addFile` is *necessary* there and must be preserved.

## Acceptance Criteria

- **AC-1**: The build succeeds. `cmake --build <build-dir>` exits 0 with no new errors.
- **AC-2**: A HIP reproducer with a `__constant__` pointer and a `__constant__` scalar set via
  `hipMemcpyToSymbol` reports the correct values from inside an instrumented clone under
  `omniprobe -i`, with **no** `-k` argument. A regression test asserting this is added under
  `tests/` and passes.
- **AC-3**: The same reproducer still passes when run *with* a `-k` regex that matches its
  kernel — i.e. matching the filter no longer selects a different (broken) copy.
- **AC-4**: `tests/run_all_tests.sh` shows no regression against the recorded baseline in this
  packet's `baseline-run_all_tests.txt`, and **no suite is skipped**. Note the baseline is not
  green: at `74c6ed2`, before any change, 1 suite passed, 4 skipped for unset environment
  variables, and 1 (Handler tests) failed on `Expected pattern not found: 'memory heatmap
  report'`. That failure is pre-existing and out of scope; fixing it is not part of this
  workflow. The criterion is stated against the baseline rather than as "the suite passes"
  because the latter is unachievable here and would block this packet for an unrelated reason.
- **AC-5**: Triton integration is not regressed: `tests/triton/run_test.sh` **runs** and passes.
  A skip does not satisfy this. The script exits 0 while printing `SKIP: TRITON_DIR not set`
  when that variable is unset, so `TRITON_DIR` must be set for this criterion to mean anything.
  This is the change's largest regression risk — `coCache::addFile` exists for Triton, and this
  packet changes when it is used.
- **AC-6**: `omniprobe -i -a MemoryAnalysis` output on an unaffected workload is unchanged
  against a baseline captured before the change (no `__constant__` use → no behaviour delta).
- **AC-7**: `-k <regex>` restricts which kernels are dispatched instrumented, per its documented
  meaning: a kernel not matching the regex runs its original, and a kernel matching it runs the
  clone. Asserted by a test that checks recorded-access presence per kernel under a filter.
- **AC-8**: A filtered run still gets DWARF source-line correlation for the kernels it does
  instrument — i.e. no sacrificial-kernel requirement remains.
- **AC-9**: The duplicate load is not merely bypassed but avoided for HIP fat binaries whose
  clones are already bound to the executable. Verified by counting `Adding` lines in a run log:
  materially fewer than the 95 observed on PENNANT for an equivalent workload.
  **[judgement]** — reason: "materially fewer" depends on the workload's shared-library count,
  which is not fixed across machines or ROCm versions; a pinned number would be a false gate.
  The mechanical part (the count is *lower* than an equivalent pre-change baseline) is checked;
  whether the remaining loads are all legitimately Triton-path is a human call.

## Failure Policy

stop

## Scope

- `src/utils.cc` / `inc/utils.h` — `coCache::addFile`, `registerRuntimeKernel`, the
  `lookup_map_` / `kernel_co_map_` writers and their precedence.
- `src/interceptor.cc` — the clone-swap gate at line 790 and the on-demand `scanCodeObject`
  block at 802–808.
- `tests/` — regression tests for AC-2, AC-3, AC-7, AC-8.
- `docs/` — correct the documented meaning of `-k` if the implementation now matches it.

## Non-Goals

- **Do not remove or break the Triton path.** `coCache::addFile` stays; Triton's instrumented
  kernels live in the JIT cache and are not in any executable the application loaded.
- No change to the instrumentation passes or to the emitted clones.
- No change to analysis handlers or to the message format.
- Not in this packet: the `gfx950` → CDNA2-bitcode misselection
  (`src/instrumentation/InstrumentationCommon.cpp:109`) and the missing `gfx950` entry in
  `external/dh_comms/include/message.h:44`. Related, separately filed — see Dependencies.
- Not in this packet: the two `-fgpu-rdc` problems found in the same session (see References);
  they need their own packets.
- Not in this packet: the malformed JSON output (leading bare `,`, no enclosing `[ ]`).

## Constraints and Assumptions

- The bug reproduces at `74c6ed2` (2026-08-26), VERSION 0.1.0. All line anchors above are
  verified at that commit and will drift if the tree moves; re-check before editing.
- Reproduced on `gfx950` / ROCm 7.2.0 with a `build_gfx950` tree. **Assumed, not verified**, to
  be architecture-independent — the mechanism is a host-side HSA loading question with nothing
  arch-specific in it, but it has only been observed on one architecture.
- The instrumented build is ~880× slower in PENNANT's own timed region, and Omniprobe startup
  (902 kernels scanned) dominates at small problem sizes. Keep reproducers small.
- **The test suite is not green at HEAD and mostly does not run.** Measured 2026-09-08: 1 suite
  passed, 4 skipped for unset environment variables, 1 failed (Handler tests). Recorded in
  `baseline-run_all_tests.txt`. Set `TRITON_DIR` and `INSTRUMENTED_ROCBLAS_LIB_DIR` before
  relying on AC-4 or AC-5.
- **`.gitignore` contains `build` only, so sibling build trees are untracked and visible to the
  scope check.** `build_gfx950/` and `build_v3.6.0_llvm/` are currently untracked in the working
  tree, and `ac_check_write_scope` reports every file in them as out of scope — a 74 KB verdict
  line that will drown any real finding, for this packet and every other one in this repository.
  Out of scope here; worth a one-line `.gitignore` fix in a separate change.

## Dependencies

- **`rf_lazy-kerneldb-loading` (suspended) — direct collision, and this packet supersedes part
  of its premise.** Its plan step 4 is *"Remove scanCodeObject dispatch-time block (lines
  802–808)"* — the exact block the `-k` workaround relies on to prime the kernelDB — and its
  invariants say *"No changes to coCache."* Both assumptions predate this finding. Sequence the
  two deliberately; do not resume that packet against a stale premise.
- `rf_rename-logduration-to-omniprobe` (suspended) also writes `src/interceptor.cc`.
- `rf_unify-kernel-discovery` (done, `.agents/kt.archive/refactors/done/`) is the packet that
  introduced `registerRuntimeKernel` and deferred the full `KernelRegistry`. Read its handoff
  before choosing an approach — the deferred design may be the right fix.
- `rf_exact-arch-bitcode` (suspended) covers the adjacent `gfx950` bitcode-selection issue in
  part; its non-goal *"No changes to dh_comms runtime library"* may not stretch to adding the
  `gfx950` enum.

## Plan Of Record

1. Reproduce at HEAD with `argprobe_g.hip`; confirm zeroed `__constant__` under `-i`.
2. Capture baselines for AC-4, AC-5, AC-6, and the `Adding`-line count for AC-9.
3. Read `rf_unify-kernel-discovery`'s dossier and handoff; decide between (a) reversing the
   first-writer precedence so `registerRuntimeKernel` wins for HIP, (b) skipping the duplicate
   load entirely when clones are already bound to the executable, or (c) the deferred
   `KernelRegistry`. (b) is the write-up's recommendation and also removes the redundant second
   load of every `.hip_fatbin`; (a) is the smaller change.
4. Implement. Keep the Triton path reachable and covered.
5. Gate the clone swap at `src/interceptor.cc:790` on the `-k` filter, leaving
   `packet->kernel_object` untouched for non-matching kernels — the `else` at
   `src/interceptor.cc:825–829` already performs exactly that restore for the `canDispatch()`
   case. This gives `-k` its documented meaning (AC-7).
6. Populate `kernel_co_map_` / trigger `scanCodeObject` regardless of the filter, so a filtered
   run still gets DWARF correlation and no sacrificial kernel is needed (AC-8).
7. Add regression tests for AC-2, AC-3, AC-7, AC-8.
8. Run the full suite; compare against baselines.
9. Investigate the one unexplained observation: `-k "gpuMain5"` at 2 ranks exits 1 with no
   accesses. If it does not resolve with the fix, file it separately rather than leaving it here.
10. Update docs and PM (`interceptor`, `sub-kerneldb`, `omniprobe-cli` units).

## Verification Strategy

| Criterion | Check |
|---|---|
| AC-1 | `cmake --build` exit status |
| AC-2 | new test under `tests/`, asserting reproducer output values under `-i` with no `-k` |
| AC-3 | same test re-run with a matching `-k` regex |
| AC-4 | `tests/run_all_tests.sh`; parse the suite tally, require 0 skipped and no regression against `baseline-run_all_tests.txt` |
| AC-5 | `tests/triton/run_test.sh`; **must run** — the script exits 0 on skip, so the check greps for `SKIP:` and fails on it |
| AC-6 | diff of `-a MemoryAnalysis` JSON against pre-change baseline (normalise the malformed-JSON wrapper first) |
| AC-7 | test asserting per-kernel recorded-access presence under a filter |
| AC-8 | test asserting non-zero DWARF line attribution in a filtered run |
| AC-9 | `Adding`-line count from the run log, compared to a pre-change baseline. Mechanical part only — see the `[judgement]` reason on AC-9 |

Note on AC-6: comparing analysis output establishes *no observable change on that workload*,
not absence of regression in general. Reported as `WEAK`.

## References

- `pennant-amp-sidecar/pennant_omniprobe.md` §3.3 and §7 — the originating write-up, with the
  full measurement table, the `-k` behaviour matrix, and a suggested fix ordering. §3.1 and §3.2
  document two further `-fgpu-rdc` problems found in the same session (duplicate
  `__hip_cuid_*` symbol from the injected `dh_comms` bitcode at device link; `.intern.<hash>`
  suffixing that breaks clone-name reconstruction in `getInstrumentedName`,
  `src/utils.cc:117`). Both are out of scope here and need their own packets.
- `pennant-amp-sidecar/.untracked/omniprobe-2026-09-01/` — `argprobe_g.hip` (the reproducer),
  `rep1.json`, `rank0.json`, `rank1.json`, `rep1.log`, `addr_k.csv`.
- `.agents/kt.archive/refactors/done/rf_unify-kernel-discovery.md` — introduced
  `registerRuntimeKernel`; records the deferral this defect lives in.

## Open Questions

1. Is the duplicate load *ever* needed for a HIP fat binary, or can it be skipped outright when
   the clones are already bound to the executable? The write-up argues it can. Unverified.
2. `-k "gpuMain5"` at 2 ranks exits 1 with no accesses. Unexplained; may be a second defect.
3. Does the bug reproduce on `gfx90a` / CDNA2? Only observed on `gfx950`. The mechanism looks
   architecture-independent but that has not been tested.
4. Should `arg_map_` (`src/utils.cc:626–634`) also move to the runtime path, or does it
   legitimately need the private copy's comgr metadata?

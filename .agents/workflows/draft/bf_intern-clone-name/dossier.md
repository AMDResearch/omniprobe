# Dossier — bf_intern-clone-name

## Metadata

- Workflow ID: bf_intern-clone-name
- Workflow Type: bugfix
- Lifecycle State: draft
- Owner / Current Executor: unassigned
- Intended Write Scope: see the `write-scope` block below (canonical)
- Dependencies On Other Active Workflows: overlaps `rf_exact-arch-bitcode` on
  `src/instrumentation/InstrumentationCommon.cpp` (that packet is *suspended*, not active, so
  this is not a live collision — but the two must not be executed in parallel)
- Base Commit: (unstamped — set at promotion)

```write-scope
src/utils.cc
src/instrumentation/InstrumentationCommon.cpp
src/instrumentation/include/InstrumentationCommon.h
tests/test_kernels/
tests/run_all_tests.sh
tests/
```

## Objective

An internal-linkage `__global__` kernel — declared `static` or in an anonymous namespace —
compiled under `-fgpu-rdc` is instrumented and analyzed exactly like an external-linkage
kernel. Concretely: `omniprobe -i` prints `Found instrumented alternative for <kernel>` for
such kernels and never `No instrumented alternative found`, **and this holds for both flavours
of the compiler-generated `.intern.<hash>` suffix** (hash beginning with a hex letter and hash
beginning with a digit).

The second clause is the whole difficulty and is not decoration. Today the two flavours take
different code paths and exactly one of them works; a fix that repairs the broken path while
regressing the working one would satisfy a naive reading of "the bug no longer reproduces" on
roughly a third of test builds and fail on the rest, non-deterministically.

## Background / Context

### Symptom as reported

PENNANT `sedovsmall`, `cstop 1` (recorded as an explicit non-goal of the completed
`bf_hip-duplicate-code-object-load`):

    No instrumented alternative found for gpuMain5(double, double const*, double const*)
      [clone .intern] [clone .de1b0b8eba669612] [clone .kd]

Those kernels run their originals and produce no analysis data. The run otherwise succeeds and
exits 0. Unlike the `__constant__`-reads-zero defect that packet fixed, this one does print a
line admitting it gave up — it is partial, *announced* data loss rather than silent.

### What was measured before this packet was written

All of the following was measured on `k005-005`-class hardware (MI210 / gfx90a), ROCm 7.2.0,
2026-09-08, using the probe sources archived in `.untracked/scratch/intern-probe/`. Nothing in
this section is inferred; the one inference that remained at filing time is called out in
`## Open Questions`.

**1. The trigger is internal linkage *plus* `-fgpu-rdc`. Both are necessary.**

A three-kernel probe (`kernel_external`, `static kernel_static`, anonymous-namespace
`kernel_anon`) compiled for gfx90a:

| build | `kernel_external` | `kernel_static` | `kernel_anon` |
|---|---|---|---|
| with `-fgpu-rdc` | `_Z15kernel_externalPim` | `_ZL13kernel_staticPim.intern.<hash>` | `_ZN12_GLOBAL__N_111kernel_anonEPim.intern.<hash>` |
| without `-fgpu-rdc` | `_Z15kernel_externalPim` | `_ZL13kernel_staticPim` | `_ZN12_GLOBAL__N_111kernel_anonEPim` |

Without `-fgpu-rdc` no `.intern.` suffix is produced at all. `static` and anonymous-namespace
behave identically. This confirms the hypothesis recorded in `current-focus.md` and settles the
part of it that was explicitly marked untested.

**2. The hash is per-translation-unit, not per-symbol.** Both internal-linkage kernels in the
probe received the *same* suffix. Consequence: every internal-linkage kernel in a TU shares one
fate. This matches the field report, where all four `static` PENNANT kernels failed together and
the one external-linkage kernel worked.

The hash is also not stable across compilations of the same source: the probe produced
`26db06f5c7a9cf0b` uninstrumented and `69c48a2e06e7f383` with the instrumentation plugin loaded.
No test may pin a literal hash.

**3. The instrumentation pass *does* emit a clone for these kernels.** This is the fork that
decides what kind of defect this is, and it falls on the benign side:

    __amd_crk__ZL13kernel_staticPim.intern.69c48a2e06e7f383Pv
    __amd_crk__ZN12_GLOBAL__N_111kernel_anonEPim.intern.69c48a2e06e7f383Pv

The instrumented code exists and is loadable. Nothing needs to be generated that is not already
being generated. This is purely a **name-reconstruction and lookup-key** defect.

**4. There are two distinct defects, and they currently cancel out most of the time.**

`lookup_map_` (`src/utils.cc:690`) is keyed by `kernelDB::demangleName(<symbol>)`, for the
original and the clone alike. At dispatch, `interceptor.cc:790` takes the original's key and
runs it through `getInstrumentedName` (`src/utils.cc:117`) to construct the clone's key.

*Defect A — `src/instrumentation/InstrumentationCommon.cpp:211`.* The pass builds the clone name
as `"__amd_crk_" + OrigKernel->getName() + "Pv"`, appending `Pv` to the **end of the whole
symbol**, i.e. after the `.intern.<hash>` suffix. That is not a well-formed mangled name — the
suffix must trail the mangling, not sit inside it. Measured:

    _ZL8gpuMain5dPKdS0_.intern.de1b0b8eba669612Pv.kd   __cxa_demangle status=-2  (fails)
    _ZL8gpuMain5dPKdS0_Pv.intern.de1b0b8eba669612.kd   __cxa_demangle status= 0  gpuMain5(double, double const*, double const*, void*) [clone .intern] [clone .de1b0b8eba669612] [clone .kd]

So the clone's `lookup_map_` key is always the **raw mangled string**, because `demangleName`
falls through both of its attempts and returns its input unchanged.

*Defect B — `src/utils.cc:117`.* `getInstrumentedName` has no notion of clone decorations. Its
demangled branch finds the last `)` and splices in `, void*`, leaving the trailing
`[clone …]` decorations attached; its mangled branch inserts `Pv` before `.kd`, which is the
wrong position per Defect A's measurement above.

*Why it usually works anyway.* The libstdc++ clone-suffix grammar accepts `.<identifier>`
(letter- or underscore-leading) and `.<all-digits>`, but rejects a digit-leading token
containing letters. Measured, varying only the first character of the hash:

    _ZL13kernel_staticPim.intern.69c48a2e06e7f383.kd   status=-2  (null)
    _ZL13kernel_staticPim.intern.a9c48a2e06e7f383.kd   status= 0  kernel_static(int*, unsigned long) [clone .intern] [clone .a9c48a2e06e7f383] [clone .kd]

Therefore:

| leading hex digit of hash | original demangles? | branch taken | outcome |
|---|---|---|---|
| `a`–`f` (6/16) | yes | demangled | **BUG FIRES** — builds `__amd_crk_gpuMain5(…, void*) [clone .intern] …`, matches no key |
| `0`–`9` (10/16) | no | mangled | **works by accident** — builds the raw string, which equals the raw key |

The feature works precisely when *both* demangles fail together, so the two defects cancel. The
defect rate is ~37.5% per translation unit, decided by one character of a content hash.

**5. End-to-end confirmation, in-repo, both arms.** Sixteen padding variants of the probe were
built; 6 produced letter-leading hashes and 10 digit-leading — the predicted 6/16. Running
`omniprobe -i -a memory_analysis` over one of each:

    variant 1 (hash e4c12f46470e7d27, letter-leading)
      Found instrumented alternative for kernel_external(int*, unsigned long) [clone .kd]
      No instrumented alternative found for kernel_static(int*, unsigned long) [clone .intern] [clone .e4c12f46470e7d27] [clone .kd]
      No instrumented alternative found for (anonymous namespace)::kernel_anon(int*, unsigned long) [clone .intern] [clone .e4c12f46470e7d27] [clone .kd]

    variant 2 (hash 58ef3701a92eeda1, digit-leading)
      Found instrumented alternative for kernel_external(int*, unsigned long) [clone .kd]
      Found instrumented alternative for _ZL13kernel_staticPim.intern.58ef3701a92eeda1.kd
      Found instrumented alternative for _ZN12_GLOBAL__N_111kernel_anonEPim.intern.58ef3701a92eeda1.kd

Note the second block's message text: it prints the *raw mangled* name, which is the visible
signature of the accidental path.

**PENNANT is not needed as a reproducer** and should not be used as one. Its tree
(`branch mi300a` at `088a2a3`) carries uncommitted build fixes, so it is not reproducible from a
clean checkout.

### Why this is easy to get wrong

A reproducer built the obvious way is a coin flip: ~62% of builds land a digit-leading hash and
pass while the defect is fully present. A regression test that does not *force* the letter-leading
case, or does not fail loudly when it does not get one, will silently stop testing anything —
the same class of failure as the log-line rename recorded in `current-focus.md` under
Project-Level Risks.

## Contract

Fix the name reconstruction so that the clone symbol emitted by the instrumentation pass and the
lookup key constructed at dispatch agree, for internal-linkage kernels under `-fgpu-rdc`, in both
hash flavours, without regressing external-linkage kernels.

## Acceptance Criteria

- **AC-1**: A regression fixture exists in-repo containing at least one `static` and one
  anonymous-namespace `__global__` kernel alongside an external-linkage one, compiled with
  `-fgpu-rdc` and the instrumentation plugin. Decided by: the fixture source and its
  registration exist, and building it yields a code object containing at least one
  `.intern.<hash>` symbol.
- **AC-2**: The fixture's test exercises a **letter-leading** hash deterministically — not by
  hoping the compiler produces one. Decided by: the test emits the hash it exercised and asserts
  its leading character is in `[a-f]`; the assertion fails the test if not.
- **AC-3**: The fixture's test also exercises a **digit-leading** hash, and asserts success there
  too. This is the anti-regression arm: it fails if a fix repairs the demangled path by breaking
  the accidental mangled path.
- **AC-4**: For every kernel in the fixture, an instrumented run prints
  `Found instrumented alternative for` and prints `No instrumented alternative found for` for
  none of them, under both AC-2 and AC-3 conditions.
- **AC-5**: The test fails loudly, rather than passing vacuously, if the built fixture contains
  no `.intern.` symbol at all — e.g. if a future toolchain stops emitting the suffix, or
  `-fgpu-rdc` is dropped from the fixture's compile flags.
- **AC-6**: The new suite is registered in `tests/run_all_tests.sh` and runs as part of it.
- **AC-7**: External-linkage kernels are unaffected: the pre-existing suites that depend on
  instrumented-alternative resolution still pass.
- **AC-8**: `tests/run_all_tests.sh` on a gfx90a node with `.untracked/test-env.sh` sourced
  reports every suite passed, 0 failed, 0 skipped.
- **AC-9**: The fixture's test fails at the base commit and passes at HEAD. Decided by running
  the new test against a build of the base commit. **[judgement]** — reason: it requires building
  and running a second tree at a different commit, which the acceptance script cannot do
  hermetically inside a single run; the evidence is recorded in `run-log.md` and `artifacts.md`
  and a human confirms it. The mechanical half (that the test passes at HEAD) is AC-4.

## Failure Policy

`stop`. If the root cause turns out to differ from the account in Background above, report rather
than applying a speculative fix. In particular, do not "fix" this by making `getInstrumentedName`
strip `[clone …]` decorations without first establishing what the clone's key actually is on the
build under test — the two defects interact and a one-sided change regresses the majority case.

## Scope

- `getInstrumentedName` in `src/utils.cc`.
- The clone-name construction at `src/instrumentation/InstrumentationCommon.cpp:211` and its
  documenting comment in `src/instrumentation/include/InstrumentationCommon.h:62`.
- A new regression fixture under `tests/test_kernels/` and its test script under `tests/`.
- Registration of the new suite in `tests/run_all_tests.sh`.

## Non-Goals

- Changing `kernelDB::demangleName` in `external/kerneldb`. It is a **git submodule** with its own
  upstream (`AMDResearch/kerneldb`); a change there is a cross-repository commit and is out of
  scope for this packet. If the chosen fix genuinely requires it, stop and re-specify.
- Reworking the mangled-versus-demangled `lookup_map_` keying scheme. That the map is keyed by a
  string whose form depends on whether a demangler happened to succeed is the deeper design
  problem here, and it is a refactor, not a bug fix. Record it as a follow-up.
- Any change to how `-fgpu-rdc` or the HIP toolchain generates `.intern.<hash>`. That is compiler
  behaviour and is treated as fixed input.
- The `rf_exact-arch-bitcode` gfx950 bitcode-selection work, which touches the same file.

## Constraints and Assumptions

- Must be verified on a **gfx90a** node. `build/` is a gfx90a tree; a gfx90a binary on a gfx950
  GPU fails to dispatch silently and exits 0 with no output, which has previously manufactured
  two phantom defects in this repository.
- `.untracked/test-env.sh` must be sourced; `LD_LIBRARY_PATH` must include the build directory.
- No test may pin a literal `.intern.<hash>` value — the hash varies with module content and
  compile flags (measured: same source, two hashes, with and without the plugin).
- `tests/test_kernels/*` already compile with `-fgpu-rdc`, so the fixture does not need to arrange
  the flag; `tests/test_kernels/filter_semantics_test.hip` is the structural template.
- A latent classifier bug in `tests/run_all_tests.sh:59` marks a whole suite *skipped* if the
  string `SKIP` appears anywhere in its output. The new test must not emit that string, or AC-8
  will misreport.

## Dependencies

- None blocking. Sequencing note: `rf_exact-arch-bitcode` writes the same file
  (`src/instrumentation/InstrumentationCommon.cpp`) and must not run concurrently.

## Plan Of Record

1. **Reproduce from a committed fixture.** Port the probe in `.untracked/scratch/intern-probe/`
   into `tests/test_kernels/` and confirm the failure end-to-end. Pre-packet evidence already
   establishes the reproduction (see Background §5) but it lives in untracked scratch; the packet
   is not started until the reproduction is in-tree and re-runnable.
2. **Settle the determinism mechanism for AC-2/AC-3.** Decide how the test forces each hash
   flavour. Options identified, none yet chosen — see `## Open Questions`.
3. **Confirm the root-cause account against the build under test** — specifically, that the clone
   key is the raw mangled string and the original key is decoration-decorated, by instrumenting or
   dumping the two keys rather than by re-deriving them.
4. **Implement the fix.** Expected to be a coordinated pair: move `Pv` inside the mangling in the
   pass, and teach `getInstrumentedName` the matching rule. Verify both halves land together.
5. **Add the regression test** covering both flavours and the vacuity guard (AC-5).
6. **Verify**: new suite, then full `tests/run_all_tests.sh` on gfx90a.
7. **Record** the follow-up refactor (lookup-key scheme) as a seed or a note in `current-focus.md`.

## Verification Strategy

| Criterion | Check |
|---|---|
| AC-1 | fixture source present; `llvm-nm` of the built code object greps `\.intern\.[0-9a-f]+` |
| AC-2 | test output names the exercised hash; script asserts `^[a-f]` |
| AC-3 | test output names a digit-leading hash exercised in the same run |
| AC-4 | grep run output for `No instrumented alternative found` — must be absent; count of `Found instrumented alternative` must equal the fixture's kernel count |
| AC-5 | negative check: assert the test's own guard fires when `.intern.` is absent |
| AC-6 | `grep run_suite tests/run_all_tests.sh` names the new script — text presence only, report `WEAK` |
| AC-7 | pre-existing suites in `run_all_tests.sh` pass |
| AC-8 | `tests/run_all_tests.sh` exits 0; tally line shows 0 failed and 0 skipped |
| AC-9 | `[judgement]` — human confirms the base-commit failure from `run-log.md` evidence |

Note on AC-4: counting `Found instrumented alternative` lines is a presence check on a **log
string**. This repository has twice been bitten by a log-line rename silently re-pointing
assertions written against it (see `current-focus.md`, Project-Level Risks). If the fix changes
that message, the test must be updated in the same commit.

## References

- `.agents/workflows/done/bf_hip-duplicate-code-object-load/dossier.md` — the completed packet
  that surfaced this as an explicit non-goal; source of the `_ZL8gpuMain5dPKdS0_` field report.
- `.agents/state/current-focus.md` — "Immediate Next Recommended Actions" item 1, the framing this
  packet tested and confirmed.
- `.untracked/scratch/intern-probe/` — probe sources and measurement programs:
  `probe.hip` (three-kernel fixture), `namecheck.cc` (reproduces `demangleName` and
  `getInstrumentedName` verbatim and prints the match verdict), `hashcheck.cc` (the clone-suffix
  grammar measurement), `target.cc` (the `Pv`-placement measurement).
- `src/utils.cc:117` `getInstrumentedName`; `src/utils.cc:690` `lookup_map_` population;
  `src/utils.cc:805` `findInstrumentedAlternative`; `src/interceptor.cc:790` dispatch site.
- `src/instrumentation/InstrumentationCommon.cpp:211` clone-name construction.
- `external/kerneldb/src/kernelDB.cc:98` `demangleName`.

## Open Questions

1. **How does the test force each hash flavour deterministically?** Three options, none chosen:
   (a) `llvm-objcopy --redefine-sym` on the built code object to rewrite the hash to a fixed
   letter-leading and digit-leading value — fully deterministic, but tests a synthesised symbol
   rather than one the compiler produced; (b) build N padding variants of the fixture and select
   one of each flavour at test time — tests genuine compiler output, but N must be large enough
   that "no letter-leading variant" is vanishingly unlikely (`0.625^N`; N=8 gives ~2.3%, N=16
   ~0.05%) and it costs N compilations; (c) a unit-level test over the name-reconstruction
   function with synthetic names, plus a single end-to-end fixture asserting whichever flavour it
   got. Likely answer is (c) for the gating assertion plus (a) for one end-to-end arm, but this is
   a real design decision and belongs to execution.
2. **Is the `Pv`-inside-the-mangling form the right fix, or should the lookup stop going through
   demangled names at all?** Moving `Pv` changes a symbol name that other tooling may match on —
   `tests/rocblas_hipblaslt/run_test.sh:86` greps for `__amd_crk_Cijk`, and instrumented rocBLAS
   and hipBLASLt libraries were built against the *current* naming. Whether pre-built instrumented
   libraries would still resolve after a pass-side rename is **not measured** and must be checked
   before step 4 is executed; it may force the fix entirely onto the `src/utils.cc` side.
3. Does the same defect affect `getArgDescriptor` (`src/utils.cc:439`, `:471`), which calls
   `getInstrumentedName` against `arg_map_`? Not measured. Likely yes, and likely fixed by the
   same change, but it should be confirmed rather than assumed.

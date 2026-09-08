# Run-Log

Append an entry after every meaningful execution step. This is not optional. If the session is
interrupted, this log is the only record of progress.

## Log Entries

### 2026-09-08 08:30

- **Actor**: claude
- **Planned step**: Pre-packet probe — test the `current-focus.md` hypothesis that a `static`
  `__global__` kernel under `-fgpu-rdc` receives a `.intern.<hash>` symbol, before writing any
  packet around it.
- **Action taken**: Built a three-kernel HIP probe (external-linkage, `static`,
  anonymous-namespace) for gfx90a, twice: with and without `-fgpu-rdc`. Extracted the code object
  from `.hip_fatbin` via `llvm-objcopy` + `clang-offload-bundler` and listed symbols with
  `llvm-nm`.
- **Result**: success. With `-fgpu-rdc`, both internal-linkage kernels carry
  `.intern.26db06f5c7a9cf0b`; the external-linkage kernel does not. Without `-fgpu-rdc`, no
  `.intern.` suffix appears on any of the three. Both conditions are necessary. Anonymous
  namespace behaves identically to `static`. The hash is shared by both internal-linkage kernels —
  it is per-translation-unit, not per-symbol.
- **Files touched**: `.untracked/scratch/intern-probe/probe.hip` (new, untracked)
- **Verification**: `llvm-nm` symbol listings for both arms, recorded in session transcript.
- **Criteria impact**: none yet — packet not created at this point.
- **Blocker / Risk**: none. PENNANT confirmed redundant as a reproducer.

### 2026-09-08 08:33

- **Actor**: claude
- **Planned step**: Determine whether the instrumentation pass emits a clone for internal-linkage
  kernels at all — the fork deciding whether this is a name-reconstruction defect or a
  missing-code defect.
- **Action taken**: Rebuilt the probe with `-fpass-plugin=build/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so`
  and grepped the resulting code object for `__amd_crk_` symbols.
- **Result**: success. Clones exist for all three kernels, including
  `__amd_crk__ZL13kernel_staticPim.intern.69c48a2e06e7f383Pv`. The instrumented code is present
  and loadable — this is purely a lookup/name defect. Also noted: the hash changed from
  `26db06f5c7a9cf0b` to `69c48a2e06e7f383` for the same source under different flags, so no test
  may pin a literal hash.
- **Files touched**: none tracked.
- **Verification**: `llvm-nm` of the instrumented code object.
- **Criteria impact**: none yet.
- **Blocker / Risk**: the plugin used is dated 2026-06-01, older than HEAD. It is the shipped
  build-tree plugin and the completed bugfix touched `src/interceptor.cc`, not the pass, so this
  is judged not to affect the result — but it is an assumption, not a measurement.

### 2026-09-08 08:40

- **Actor**: claude
- **Planned step**: Establish what `getInstrumentedName` actually produces versus the actual
  `lookup_map_` key, rather than reasoning about it.
- **Action taken**: Wrote `namecheck.cc` reproducing `kernelDB::demangleName`
  (`external/kerneldb/src/kernelDB.cc:98`) and `getInstrumentedName` (`src/utils.cc:117`)
  **verbatim**, and ran it over the probe's measured symbols plus the PENNANT field report's
  `_ZL8gpuMain5dPKdS0_`.
- **Result**: success, and it **contradicted the expected outcome**. The probe's own
  `static` kernel MATCHED — the defect did not reproduce. PENNANT's `gpuMain5` did not match.
  The difference: `__cxa_demangle` succeeds on `.intern.de1b…` and fails on `.intern.69c4…`.
- **Files touched**: `.untracked/scratch/intern-probe/namecheck.cc` (new, untracked)
- **Verification**: program output, both arms, in session transcript.
- **Criteria impact**: none yet.
- **Blocker / Risk**: a naive reproducer would have passed and the packet would have been filed
  against a symptom that does not reproduce. Chasing the contradiction is what produced the
  finding below.

### 2026-09-08 08:45

- **Actor**: claude
- **Planned step**: Isolate why `__cxa_demangle` accepts one hash and rejects another.
- **Action taken**: Wrote `hashcheck.cc` varying only the first character of the hash across five
  forms (digit-leading mixed, letter-leading mixed, all-digits, all-letters, and the real PENNANT
  symbol both ways).
- **Result**: success. The libstdc++ clone-suffix grammar accepts `.<identifier>` (letter- or
  underscore-leading) and `.<all-digits>`, and rejects a digit-leading token containing letters
  (`status=-2`). So a hex hash beginning `a`–`f` demangles and one beginning `0`–`9` (with any
  letter present) does not. **The defect is intermittent at ~37.5% per translation unit, decided
  by one character of a content hash.**
- **Files touched**: `.untracked/scratch/intern-probe/hashcheck.cc` (new, untracked)
- **Verification**: program output.
- **Criteria impact**: this is the origin of AC-2, AC-3 and AC-5 — a regression test that does not
  force the letter-leading case silently tests nothing ~62% of the time.
- **Blocker / Risk**: none.

### 2026-09-08 08:50

- **Actor**: claude
- **Planned step**: Establish the correct target string for the fix — where `Pv` would have to sit
  for the clone symbol to be a well-formed mangled name.
- **Action taken**: Wrote `target.cc` demangling the clone symbol with `Pv` in its current
  position (after the `.intern.<hash>` suffix) and in the alternative position (attached to the
  base mangling, before the suffix).
- **Result**: success. Current position fails to demangle (`status=-2`); the alternative
  demangles cleanly. This identifies a **second, independent defect** at
  `src/instrumentation/InstrumentationCommon.cpp:211`, and explains why the digit-leading case
  works: both demangles fail together and the two defects cancel.
- **Files touched**: `.untracked/scratch/intern-probe/target.cc` (new, untracked)
- **Verification**: program output.
- **Criteria impact**: origin of AC-3 — fixing either defect alone regresses the other half of
  the cases, and the majority half is the one that currently works.
- **Blocker / Risk**: raised as Open Question 2 — a pass-side rename changes every clone symbol
  and may break pre-built instrumented rocBLAS/hipBLASLt libraries. Unmeasured.

### 2026-09-08 08:55

- **Actor**: claude
- **Planned step**: Confirm the whole account end-to-end under the real `omniprobe` runtime,
  both arms.
- **Action taken**: Built 16 padding variants of the probe to sample the hash distribution, then
  ran `omniprobe -i -a memory_analysis` over one letter-leading variant (`e4c12f46470e7d27`) and
  one digit-leading variant (`58ef3701a92eeda1`) on gfx90a with `.untracked/test-env.sh` sourced.
- **Result**: success, exactly as predicted. 6 of 16 variants were letter-leading (predicted
  6/16). The letter-leading variant printed `No instrumented alternative found` for both
  internal-linkage kernels and `Found instrumented alternative` for the external one. The
  digit-leading variant found all three — printing the raw mangled names, the visible signature of
  the accidental path.
- **Files touched**: `.untracked/scratch/intern-probe/v*.hip` (new, untracked)
- **Verification**: `omniprobe -i -a memory_analysis` output for both variants, exit 0 both times.
- **Criteria impact**: establishes AC-9's base-commit-failure evidence in untracked form; the
  packet still requires it in-tree (Plan Of Record step 1).
- **Blocker / Risk**: none. PENNANT is confirmed unnecessary, which matters because its tree has
  uncommitted build fixes and is not reproducible from a clean checkout.

### 2026-09-08 09:05

- **Actor**: claude
- **Planned step**: File the bugfix packet.
- **Action taken**: Created `.agents/workflows/draft/bf_intern-clone-name/` with `dossier.md`,
  `handoff.md`, `run-log.md`, `artifacts.md`, `acceptance.sh`; registered the row in
  `.agents/state/active-workflows.md`.
- **Result**: success.
- **Files touched**: the five packet files; `.agents/state/active-workflows.md`
- **Verification**: `bash .agents/workflows/draft/bf_intern-clone-name/acceptance.sh` — expected
  to FAIL at draft, since no fix or fixture exists yet.
- **Criteria impact**: none met. All criteria open by design at draft.
- **Blocker / Risk**: Open Question 2 must be measured before Plan Of Record step 4.

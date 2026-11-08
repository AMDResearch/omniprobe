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

### 2026-09-08 09:25

- **Actor**: claude
- **Planned step**: Run `workflow-readiness-check` and, if it passes, promote to `active`.
- **Action taken**: Ran the full checklist. Structural items all passed. Step 3's pattern-collision
  audit — "could this pattern match text that exists *because of* the thing being tested for?" —
  found three defects in `acceptance.sh` and one looseness, and each was repaired and then tested
  against input that should pass and input that should fail.
- **Result**: success, but only after repair. **AC-6 was a vacuous PASS**: it grepped
  `run_all_tests.sh` for a pattern built from the new test's own path components, and both
  plausible layouts match the *untouched* file (`tests` hits `run_handler_tests.sh`; `run_test.sh`
  already appears 5 times). Proven by running the check against the unmodified runner — it
  reported satisfied. Replaced with a behavioural check on the suite banner
  (`run_all_tests.sh:40`); `intern` has 0 hits in that file today, so nothing predating
  registration can satisfy it. **AC-5** grepped the test script's source for guard wording, which
  a comment satisfies — replaced with a behavioural check requiring non-zero exit under
  `AC_FORCE_NO_INTERN=1`. **AC-4** was the opposite direction, a false-FAIL risk: an unanchored
  grep matches a test echoing its own commentary about the string; both patterns now anchor to
  column 0. **AC-1**'s bare `namespace` grep matched `using namespace std;` and was anchored.
- **Files touched**: `acceptance.sh`, `dossier.md` (Verification Strategy rows and the rationale
  for each indirect check)
- **Verification**: `bash -n` clean; gate runs to completion reporting 8 FAIL / 1 JUDGE / 1 PASS
  (SCOPE) — the correct pre-work state. Each repaired pattern discriminated correctly in both
  directions on synthetic inputs.
- **Criteria impact**: none met. No acceptance criterion changed — verification got stricter, the
  contract did not get looser.
- **Blocker / Risk**: none new. Open Question 2 remains the live risk to step 4.

### 2026-09-08 09:30

- **Actor**: claude
- **Planned step**: Promote `draft` → `active`.
- **Action taken**: `git mv` of the packet directory, stamped `Base Commit: e2aa500`, set
  `Lifecycle State: active`, updated the row in `.agents/state/active-workflows.md`, and rewrote
  the handoff's Current Status and Next Exact Step.
- **Result**: success.
- **Files touched**: packet directory (moved), `dossier.md`, `handoff.md`,
  `.agents/state/active-workflows.md`
- **Verification**: `acceptance.sh` re-run from the new location — `SCOPE` still `PASS`, proving
  the sibling-dossier lookup survives the move; tally unchanged at 8 FAIL / 1 JUDGE.
- **Criteria impact**: none.
- **Blocker / Risk**: none.

### 2026-09-08 10:20

- **Actor**: claude
- **Planned step**: Resolve a write-scope overlap surfaced while filing two sibling packets.
- **Action taken**: Narrowed this packet's `write-scope` block — replaced the bare `tests/` with
  `tests/test_intern_clone.sh` and `tests/intern_clone/`. Added the shared-file coordination rule
  for `tests/run_all_tests.sh`, which three active packets now append to.
- **Result**: success. The only path shared with another active packet is now
  `tests/run_all_tests.sh`, which is shared on purpose and append-only.
- **Files touched**: `dossier.md`, `handoff.md`, `run-log.md`
- **Verification**: `acceptance.sh` re-run — `SCOPE` still `PASS`; tally unchanged.
- **Criteria impact**: none.
- **Blocker / Risk**: if the regression test lands outside the two declared paths, the executing
  agent hits a scope FAIL and amends. That is the intended behaviour, not a defect.

### 2026-09-08 10:35

- **Actor**: claude
- **Planned step**: Restore a meaningful `SCOPE` verdict after sibling packets landed.
- **Action taken**: Re-stamped `Base Commit` from `e2aa500` to `5b9425f`.
- **Result**: success. The old stamp predated `bf_exit-status-not-propagated` and
  `bf_pyhandler-gil`, so the scope check was measuring *their* commits — correctly reporting
  another workflow's packet directories as out-of-scope writes, but for this packet that is noise
  rather than signal. The stamp now sits at the point where this packet's own work begins.
- **Files touched**: `dossier.md`
- **Verification**: `acceptance.sh` re-run — `SCOPE` back to `PASS`.
- **Criteria impact**: none.
- **Blocker / Risk**: none. Worth knowing generally: a base commit stamped early enough for other
  work to land in between turns the scope check into a report on the repository rather than on the
  packet.

### 2026-11-08 — executed and completed (opimpl, supervised run; moved up the queue on Pennant evidence)

- Determinism (Open Question 1): clang's `-cuid=` pins the .intern hash (hash = f(cuid) only,
  same with and without the plugin). Fixture `tests/test_kernels/intern_linkage_test.cpp` built
  twice: `-cuid=a` → `a8b6f1c0b975c10c` (letter), `-cuid=c` → `37b7379df0088a4a` (digit).
- Reproduced exactly as diagnosed (letter: static/anon "No instrumented alternative").
- **New finding**: the digit arm "worked" only for clone lookup — kernelDB keys undemangleable
  names by dropping the last '.'-component (the hash), the handler's lookup kept it, so every
  access lost DWARF attribution and MemoryAnalysis reported 0 accesses for those kernels, silently.
- Open Question 2: fix is runtime-only; clones are not renamed (prebuilt rocBLAS/hipBLASLt suites
  pass). Open Question 3: getArgDescriptor uses the same keys (arg_map_ built via the same
  demangling), covered by the fix.
- Fix `3e31ee8`: `demangleKernelName` (uniform decorated demangling for both flavours, Pv repair
  for clones), `kernelDBName` threaded to handlers, end-of-run summary of kernels without a clone.
- New suite 16; unfixed source (same fixture/test) →
```
  ✓ PASS - hash a8b6f1c0b975c10c is letter-leading
  ✗ FAIL - not instrumented: kernel_static kernel_anon
  ✗ FAIL - BAD ['kernel_static: 0 accesses', 'kernel_anon: 0 accesses']
  ✓ PASS - hash 37b7379df0088a4a is digit-leading
  ✓ PASS - all three kernels ran their instrumented clones
  ✗ FAIL - BAD ['kernel_static: 0 accesses', 'kernel_anon: 0 accesses']
  ✗ FAIL - no end-of-run summary for the uninstrumented kernel (see /work1/amd/rvanoo/repos/omniprobe/tests/test_output/intern_linkage/plain.log)
```
  Fixed: 7/7. Full suite 16/16.
- Pennant (copy of ~/repos/pennant incl. its working-tree patch, built in /tmp with
  `-fgpu-rdc`, gfx90a, this repo's plugin; hash `bb7720288b8abfe1`): unfixed, 6 kernels ran
  uninstrumented (calcCornersPerPoint, gpuInvMap, gpuMain3_interior, gpuMain4, gpuMain5,
  storeCornersByPoint); fixed, all instrumented with attributed accesses.
- acceptance.sh (fixture glob widened to .cpp; base re-stamped to 05b39fd; scope amended):
```
PASS  AC-1     fixture present and its build produced a .intern.<hash> symbol
PASS  AC-2     test output names a letter-leading .intern.<hash>
PASS  AC-3     test output names a digit-leading .intern.<hash>
PASS  AC-4     all fixture kernels resolved (6 found, 0 unresolved)
PASS  AC-5     vacuity guard fires: test exits 1 when forced to see no .intern. symbol
PASS  AC-6     the new suite is registered and actually ran inside run_all_tests.sh
PASS  AC-7     pre-existing suites pass — no external-linkage regression
PASS  AC-8     run_all_tests.sh: exit 0, 0 failed, 0 skipped
JUDGE AC-9     the new test fails at the base commit and passes at HEAD
PASS  SCOPE    no writes outside the declared write scope (9 entries; working tree and commits since 05b39fd8b9b9c927d68f011399b8844ec054a0af)
```

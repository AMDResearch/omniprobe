# Artifacts — bf_intern-clone-name

## Pre-packet investigation (2026-09-08)

All under `.untracked/scratch/intern-probe/` — untracked by design (scratch), but the sources are
small and self-contained and can be promoted into `tests/` when Plan Of Record step 1 runs.

| File | What it is | What it established |
|---|---|---|
| `probe.hip` | Three-kernel HIP program: external-linkage, `static`, anonymous-namespace | The trigger is internal linkage **and** `-fgpu-rdc`; the hash is per-TU |
| `namecheck.cc` | Verbatim copies of `demangleName` and `getInstrumentedName`, run over measured symbols | The constructed lookup key versus the actual key, per case — the match/no-match verdict |
| `hashcheck.cc` | `__cxa_demangle` over hashes differing only in first character | The clone-suffix grammar, and hence the ~37.5% intermittency |
| `target.cc` | `__cxa_demangle` over both candidate `Pv` positions | Defect A at `InstrumentationCommon.cpp:211` — `Pv` is appended outside the mangling |
| `v1.hip` … `v16.hip` | Padding variants used to sample the hash distribution | 6/16 letter-leading, matching prediction |

## Key measured outputs

**Hash-flavour dependence** (`hashcheck`):

    _ZL13kernel_staticPim.intern.69c48a2e06e7f383.kd   status=-2  (null)
    _ZL13kernel_staticPim.intern.a9c48a2e06e7f383.kd   status= 0  kernel_static(int*, unsigned long) [clone .intern] [clone .a9c48a2e06e7f383] [clone .kd]
    _ZL13kernel_staticPim.intern.1234567890123456.kd   status= 0  kernel_static(int*, unsigned long) [clone .intern.1234567890123456] [clone .kd]

**`Pv` placement** (`target`):

    _ZL8gpuMain5dPKdS0_.intern.de1b0b8eba669612Pv.kd   st=-2  (null)      <- what the pass emits
    _ZL8gpuMain5dPKdS0_Pv.intern.de1b0b8eba669612.kd   st= 0  gpuMain5(double, double const*, double const*, void*) [clone .intern] [clone .de1b0b8eba669612] [clone .kd]

**End-to-end, both arms** (`omniprobe -i -a memory_analysis`, gfx90a, ROCm 7.2.0):

    variant 1 — hash e4c12f46470e7d27 (letter-leading)
      Found instrumented alternative for kernel_external(int*, unsigned long) [clone .kd]
      No instrumented alternative found for kernel_static(int*, unsigned long) [clone .intern] [clone .e4c12f46470e7d27] [clone .kd]
      No instrumented alternative found for (anonymous namespace)::kernel_anon(int*, unsigned long) [clone .intern] [clone .e4c12f46470e7d27] [clone .kd]

    variant 2 — hash 58ef3701a92eeda1 (digit-leading)
      Found instrumented alternative for kernel_external(int*, unsigned long) [clone .kd]
      Found instrumented alternative for _ZL13kernel_staticPim.intern.58ef3701a92eeda1.kd
      Found instrumented alternative for _ZN12_GLOBAL__N_111kernel_anonEPim.intern.58ef3701a92eeda1.kd

## Still to be produced

- The in-tree regression fixture and its test script (Plan Of Record steps 1 and 5).
- A measurement answering Open Question 2: whether pre-built instrumented rocBLAS/hipBLASLt
  libraries still resolve if the pass renames clone symbols.
- A `run_all_tests.sh` transcript at HEAD after the fix, for AC-8.
- A base-commit run of the new test showing it fails there, for AC-9.

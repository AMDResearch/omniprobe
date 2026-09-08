# Handoff

**Location**: `.agents/workflows/active/bf_hip-duplicate-code-object-load/handoff.md`

## Current Status

**Active as of 2026-09-08. No implementation work has started.** The packet was created on
2026-09-08 from a finding made on 2026-09-01 while profiling PENNANT under Omniprobe. The
diagnosis is complete and the mechanism is pinned to specific source lines; what is missing is
the fix, the tests, and a decision on which of three approaches to take (plan step 3).

`acceptance.sh` currently fails, correctly — it describes what "done" will mean and nothing has
been built yet. Last run 2026-09-08 at promotion: `1 passed, 0 weak, 0 judgement, 9 failed`.

Promoted `draft/` → `active/` on user approval after `/workflow-readiness-check` returned READY.
`- Base Commit:` is stamped at `74c6ed2dded669fe797dff5234dee4a7d1eef8ab`.

**Run the gate against the right build tree.** `AC_BUILD_DIR` defaults to `build/`, which is the
gfx90a tree; the defect has only been observed on gfx950. Use
`AC_BUILD_DIR=$PWD/build_gfx950`.

## Last Verified

**2026-09-08** — every source anchor in the dossier re-checked against this repository at
`74c6ed2` by reading the named lines. Confirmed present and as described:

| Anchor | Verified content |
|---|---|
| `src/utils.cc:117` | `std::string getInstrumentedName(const std::string& func_decl)` |
| `src/utils.cc:206` | `void coCache::registerRuntimeKernel(...)` |
| `src/utils.cc:213–214` | `if (it->second.find(name) != it->second.end()) return;  // Already registered` |
| `src/utils.cc:487` | `bool coCache::getCodeObjectRef(...)` |
| `src/utils.cc:503` | `bool coCache::addFile(const std::string& name, hsa_agent_t agent, const std::string& strFilter)` |
| `src/utils.cc:511` | `extractCodeObjects(agent, name)` |
| `src/utils.cc:610–624` | the `-k` regex block, with a bare `continue` at 616 |
| `src/utils.cc:626–634` | the `arg_map_` insert |
| `src/utils.cc:640–644` | the `lookup_map_` insert — **after** the `continue`, hence filtered |
| `src/utils.cc:645` | `kernel_co_map_[agent][strName] = {...}` — also filtered |
| `src/utils.cc:706` | `uint64_t coCache::findAlternative(...)` |
| `src/utils.cc:736` | `uint64_t coCache::findInstrumentedAlternative(...)` |
| `src/utils.cc:1023` | the `getSharedLibraries` comment distinguishing Triton from HIP |
| `inc/utils.h:184` | `lookup_map_` declaration |
| `src/interceptor.cc:790` | `if (run_instrumented_ && dispatcher_.canDispatch(alt_kernel_object))` |
| `src/interceptor.cc:802–808` | the on-demand `scanCodeObject` block |
| `src/interceptor.cc:825–829` | the `else` branch restoring `packet->kernel_object` |
| `src/interceptor.cc:964` | `kernel_cache_.registerRuntimeKernel(...)` |
| `external/kerneldb/src/co_extract.cc:181` | `extractCodeObjects(hsa_agent_t, const std::string&)` |
| `src/instrumentation/InstrumentationCommon.cpp:109` | `if (arch == "gfx940" \|\| arch == "gfx941" \|\| arch == "gfx942")` |
| `external/dh_comms/include/message.h:44` | `gcnarch` enum — no `gfx950` entry |

**One correction to the originating write-up:** it cites `findAlternative` at `src/utils.cc:945`.
That line is `KernelArgHelper::KernelArgHelper(const std::string file_name)`. The real location
is `src/utils.cc:706`. The dossier carries the corrected anchor; the write-up has not been
amended.

**Not verified:** the runtime behaviour has not been re-reproduced at `74c6ed2` in this session.
The measurements come from the 2026-09-01 PENNANT session and are reported here as that session
recorded them. Plan step 1 exists to reproduce before changing anything.

## Next Exact Step

**Plan steps 1 and 3 are DONE.** The defect is reproduced at HEAD, and the approach is chosen:
**option (b)** — skip only the executable-loading half of `coCache::addFile` for code objects the
application has already loaded, keep both halves for Triton. Open Question 1 is resolved in the
dossier; the evidence is in the run-log entries of 2026-09-08 (reproduction) and (design
decision).

**Next is plan step 4 — implement.** Start by establishing the one thing the decision rests on
and is not yet verified: **can `addFile` tell that the application has already loaded this code
object?** Try `hsa_ven_amd_loader_iterate_loaded_code_objects` (the loader API was already
upgraded to v1.01 by `rf_unify-kernel-discovery` for this class of query). If that is not
reliable, fall back to option (a) — reverse the first-writer precedence — and treat AC-8 and AC-9
as separate work; the run-log entry explains what (a) does and does not buy.

Then, in the same pass: decouple `kernel_co_map_` / `arg_map_` population from the loaded
executable's symbol loop (`src/utils.cc:585–650`), since those need only the extracted file;
gate the clone swap at `src/interceptor.cc:790` on the `-k` filter (step 5, AC-7); and populate
`kernel_co_map_` regardless of the filter (step 6, AC-8).

Plan step 2 is partly done: the AC-9 `Adding`-count baseline is captured at
`.untracked/bf_hip-dup-co/adding-before.log` (**31** loads for a single-kernel reproducer).
Still missing for step 2: the AC-6 MemoryAnalysis baseline on an unaffected workload.

## Active Risks / Blockers

- **`rf_lazy-kerneldb-loading` is one `/workflow-resume` away from being executed against a
  premise this finding invalidates.** Its plan step 4 removes `src/interceptor.cc:802–808`, the
  block that primes the kernelDB and that the `-k` workaround depends on; its invariants say
  "No changes to coCache". Both were written before this defect was known. Sequence the two
  deliberately. This is the single most important thing for the next agent to know.
- `rf_rename-logduration-to-omniprobe` also writes `src/interceptor.cc` and has a scope broad
  enough to collide with most packets. Check `active-workflows.md` before parallel execution.
- Changing which executable clones come from is a change to how *every* application is
  instrumented. Triton is the regression risk and its coverage (`tests/triton/run_test.sh`,
  5 tests) is thin for a change of this reach.
- The bug has only been observed on `gfx950` / ROCm 7.2.0. Architecture independence is assumed
  from the mechanism, not measured.

## Required Reads Before Resuming

1. This packet's `dossier.md` — §Background carries the full mechanism.
2. `.agents/kt.archive/refactors/done/rf_unify-kernel-discovery.md` — introduced
   `registerRuntimeKernel`; the deferred `KernelRegistry` may be the right fix.
3. `.agents/workflows/suspended/rf_lazy-kerneldb-loading/dossier.md` — the collision.
4. `../pennant-amp-sidecar/pennant_omniprobe.md` §3.3 — the originating write-up, including the
   `-k` behaviour matrix and the two further `-fgpu-rdc` problems (§3.1, §3.2) that need their
   own packets.
5. PM units `interceptor`, `sub-kerneldb`, `handler-pipeline`.

## Proposed Spec Changes

None.

## Scope Amendments

None.

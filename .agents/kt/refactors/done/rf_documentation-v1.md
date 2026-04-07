# Refactor: Documentation for v1.0

## Status
- [x] TODO
- [x] In Progress
- [ ] Blocked
- [x] Done

## Objective
Rewrite README.md and fill out docs/ to provide clear, accurate documentation for
the Omniprobe v1.0 release. Remove historical narrative ("was originally called
logduration"), keep CI badges, and split detailed topics into separate docs/ pages
linked from the README.

## Dependency
- `rf_rename-logduration-to-omniprobe` (TODO) — All new documentation should use the
  future `OMNIPROBE_*` env var names and `libomniprobe.so` library name. If the rename
  hasn't landed yet, write docs against the new names anyway and note the dependency.
  The rename dossier's step 6 ("Update README and documentation") becomes a no-op once
  this refactor is done.

## Refactor Contract

### Goal
Produce documentation that lets a new user understand what Omniprobe does, install it,
and use it — without needing to read source code.

### Non-Goals / Invariants
- No code changes — documentation only
- No changes to `.agents/kt/` dossiers (those are internal)
- No changes to CLAUDE.md (that's for AI sessions, not users)
- Existing docs/ files (triton-instrumentation.md, rocblas-maximal-instrumentation.md)
  may be lightly edited for consistency but are NOT being rewritten

### Verification Gates
- Links between README.md and docs/ are consistent (no broken references)
- No mentions of "logduration" history or origin story
- CI badges still present near top of README.md
- All CLI flags documented match the actual `omniprobe` script's argparse

## Scope

### README.md — Top-Level Overview

Keep this focused and scannable. Target ~150–200 lines. Structure:

```
1. CI Badges (3 existing badges, keep as-is)

2. What is Omniprobe? (~5–8 lines)
   - One-paragraph elevator pitch: instrument HIP/Triton GPU kernels
     to find memory inefficiencies, bank conflicts, etc.
   - Bullet list of key capabilities (uncoalesced access detection,
     LDS bank conflict detection, basic block analysis, memory heatmaps)

3. Quick Start (~15–20 lines)
   - Memory analysis example: instrument a HIP program, see output
   - Just enough to show the tool working end-to-end
   - Link to detailed install/build docs for full instructions

4. Installation (~10–15 lines, mostly links)
   - Brief mention of two paths: build from source, or use container
   - Link to docs/building-from-source.md (NEW)
   - Link to docs/container-usage.md (NEW)
   - Prerequisites summary (ROCm, CMake, supported GPUs)

5. Usage Overview (~30–40 lines)
   - The omniprobe CLI wrapper: what it does conceptually
   - Brief overview of each major option/mode with a one-liner example
     and a link to its dedicated section in docs/usage.md:
     - Analyzers (-a): which analysis to run
     - Instrumented mode (-i): enable instrumented kernel dispatch
     - Kernel filtering (-k): regex to select kernels
     - Dispatch capture (-d): which dispatches to instrument
     - Output format (-t) and location (-l)
     - Block index filtering (--filter-x/y/z)
     - Library filtering (--library-filter)
     - Triton cache (-c) and instrumentation scope
   - Link to docs/usage.md (NEW) for full details + examples

6. Analyzers (~10–15 lines, summary table)
   - Table: analyzer name, what it detects, one-line description
   - Link to docs/usage.md analyzer section for details on each

7. Instrumenting Libraries (rocBLAS, hipBLASLt) (~5 lines)
   - Brief mention that pre-compiled GPU libraries need special builds
   - Link to existing docs/rocblas-maximal-instrumentation.md

8. Triton Support (~5 lines)
   - Brief mention of Triton kernel instrumentation
   - Link to existing docs/triton-instrumentation.md

10. Project Structure (~10–15 lines)
    - Brief layout of the repo (src/, omniprobe/, plugins/, tests/, etc.)
    - Mention sub-projects (dh_comms, kerneldb) without deep detail

11. License
    - MIT, one line
```

### New docs/ Pages

#### docs/building-from-source.md (NEW)
Content extracted and expanded from current README + KT knowledge:
- Prerequisites (ROCm version, CMake, hipcc, C++ standard)
- Supported GPU architectures (gfx90a, gfx906, gfx908, gfx940, gfx941, gfx942)
- Clone instructions (with submodules)
- CMake configure + build + install
- Optional: building with Triton support (brief, link to triton-instrumentation.md)
- Running tests (handler tests, Triton tests)
- Troubleshooting (common build issues)

#### docs/container-usage.md (NEW)
- Two-stage container architecture explanation (toolchain + omniprobe)
- Building the Apptainer container locally
- Running omniprobe from within the container
- Docker vs Apptainer notes
- Filesystem requirements (mmap-capable filesystem for instrumented libraries)

#### docs/usage.md (NEW)
Comprehensive usage guide. Each option/feature gets its own section with
explanation, examples, and sample output where helpful. README.md links
directly to individual sections (e.g., `docs/usage.md#analyzers`).

Sections:
- **Analyzers** (`-a`): Detailed description of each analyzer
  (MemoryAnalysis, AddressLogger, BasicBlockAnalysis, Heatmap,
  BasicBlockLogger), what each detects, output format, interpretation,
  and how to specify custom handler .so files
- **Instrumented mode** (`-i`): What it does, when to use it
- **Kernel filtering** (`-k`): ECMAScript regex syntax, examples
- **Dispatch capture** (`-d`): all / random / 1, tradeoffs
- **Output format and location** (`-t`, `-l`): csv vs json, file vs console
- **Block index filtering** (`--filter-x/y/z`): Range syntax, use cases
- **Library filtering** (`--library-filter`): JSON config format, examples
- **Triton instrumentation scope** (`--instrumentation-scope`):
  file:line syntax, compile-time filtering
- **Triton cache** (`-c`): Cache location, when needed
- **Environment variables**: Full table of OMNIPROBE_* variables with
  descriptions (the env var counterparts of CLI flags, plus any
  env-only settings)
- **Verbose and debug** (`-v`, `-e`): Diagnostic options

#### docs/triton-instrumentation.md (EXISTS — light edits only)
- Already comprehensive, ~327 lines
- Update any stale references (env var names if rename lands first)

#### docs/rocblas-maximal-instrumentation.md (EXISTS — light edits only)
- Already comprehensive, ~370 lines
- Update any stale references

## Source File Reference

For each micro-step, these are the source-of-truth files to read. All paths
relative to repo root (`/work1/amd/rvanoo/repos/omniprobe/`).

### Step 1: docs/building-from-source.md

| File | What to extract |
|------|----------------|
| `CMakeLists.txt` (lines 23–164) | CMake options: `ROCM_PATH`, `CMAKE_INSTALL_PREFIX`, `TRITON_LLVM`, `CMAKE_HIP_ARCHITECTURES`, `INTERCEPTOR_BUILD_TESTING`. C++ standard (20), cmake_minimum_required (3.15) |
| `src/CMakeLists.txt` | Dependencies: HSA runtime, dh_comms, kernelDB64, rocprofiler-sdk, amd_comgr, libelf. GPU_LIST for supported architectures |
| `containers/toolchain.Dockerfile` (lines 17–21) | System package prerequisites: git, build-essential, cmake, ninja, clang, lld, libzstd-dev, libomp-dev, ccache, libdwarf-dev, python3-dev, rocm-llvm-dev |
| `containers/triton_install.sh` | Triton build prerequisites (Python 3.10+, LLVM shared library requirement) |
| `tests/CMakeLists.txt` | How tests are enabled and what they build |
| `tests/run_basic_tests.sh` | How to invoke tests |
| `tests/run_triton_tests.sh` | How to invoke Triton-specific tests |

### Step 2: docs/container-usage.md

| File | What to extract |
|------|----------------|
| `containers/build-container.sh` | Two-stage build flow, `--docker`/`--apptainer` flags, `--rocm VERSION`, supported ROCm versions (7.0, 7.1, 7.2), toolchain SIF caching |
| `containers/run-container.sh` | Running containers, `--docker`/`--apptainer` flags, workspace mounting at `/workspace`, automatic build fallback |
| `containers/toolchain.Dockerfile` | Base image (`rocm/dev-ubuntu-24.04`), LLVM build layer, Triton install layer, env vars |
| `containers/omniprobe.Dockerfile` | Layers on toolchain, pip requirements, CMake config, install to `/opt/omniprobe` |
| `containers/toolchain.def` | Apptainer equivalent of toolchain Dockerfile |
| `containers/omniprobe.def` | Apptainer equivalent of omniprobe Dockerfile |
| `containers/triton_install.sh` | `--triton-version`, `--local-sources`, `--skip-llvm` options |

### Step 3: docs/usage.md

| File | What to extract |
|------|----------------|
| `omniprobe/omniprobe` lines 549–747 | Argparse definitions: all flags, types, defaults, help strings |
| `omniprobe/omniprobe` lines 296–449 | `setup_env()`: env var names set at runtime, Triton-specific vars |
| `omniprobe/config/analytics.py` | Analyzer name → handler lib → LLVM plugin mapping (5 analyzers) |
| `src/memory_analysis_handler.cc` (top ~50 lines) | What MemoryAnalysis detects: L2 cache line waste, LDS bank conflicts, 32 banks on gfx90a |
| `src/memory_heatmap.cc` (top ~50 lines) | Heatmap: per-dispatch memory page access counts, configurable page size |
| `src/basic_block_analysis.cc` (top ~50 lines) | BasicBlockAnalysis: basic block timing with percentile calculations |
| `src/time_interval_handler.cc` (top ~50 lines) | Duration measurement: first_start, last_stop, total_time, intervals |
| `src/message_logger.cc` (top ~50 lines) | AddressLogger: raw message logging to CSV/JSON |
| `plugins/plugin.h` | Handler plugin interface: `getMessageHandlers_t` function signature |
| `tests/test_output/memory_analysis_cache_lines.out` | Sample MemoryAnalysis output for docs |
| `tests/test_output/heatmap_basic.out` | Sample Heatmap output for docs |

### Step 4: README.md

No new source files — synthesize from the docs/ pages written in steps 1–3.
Read the existing `README.md` only to preserve the 3 CI badge lines verbatim.

### Step 5: Light edits to existing docs/

| File | What to check |
|------|--------------|
| `docs/triton-instrumentation.md` | Update env var names (`LOGDUR_*` → `OMNIPROBE_*`), library names, any stale paths |
| `docs/rocblas-maximal-instrumentation.md` | Same |

## Quick-Start Sketch

The README quick-start section should use the `simple_memory_analysis_test` binary.
This test has two kernels — `coalesced_kernel` (sequential access, no issues) and
`strided_kernel` (strided access, triggers cache line waste detection) — making it
an ideal "show the tool finding a real problem" example.

**Command** (assuming build tree):
```bash
omniprobe -i -a MemoryAnalysis -- ./build/tests/test_kernels/simple_memory_analysis_test
```

**Representative output** (from `tests/test_output/memory_analysis_cache_lines.out`):
```
Found instrumented alternative for coalesced_kernel(int*, unsigned long) [clone .kd]
Found instrumented alternative for strided_kernel(int*, unsigned long, unsigned long) [clone .kd]
simple_memory_analysis_test done
=== L2 cache line use report ======================
No excess cache lines used for global memory accesses
=== End of L2 cache line use report ===============
=== Bank conflicts report =========================
No bank conflicts found
=== End of bank conflicts report ====================
```

The quick-start should briefly explain what each line means:
- "Found instrumented alternative" = omniprobe auto-swapped the original kernel for its instrumented clone
- The reports summarize memory access efficiency findings
- In real-world code with strided access patterns, the L2 cache line report would flag excess cache line usage

Note: The exact output format may change once the rename refactor lands (e.g., the
"kernel location" lines reference the build path). Keep the example generic enough
that path differences don't matter.

## README Prose Guidance

### "What is Omniprobe?" section

**Emphasize:**
- Intra-kernel visibility — this is the key differentiator. Existing tools (rocprof,
  omniperf) give per-dispatch aggregate metrics. Omniprobe instruments *inside* kernels
  to pinpoint problems at the source-line level.
- Non-invasive — no source code changes required for HIP kernels. Instrumentation
  happens at the LLVM IR level during compilation.
- Automatic kernel discovery — instrumented kernel clones are auto-swapped at dispatch time.

**Avoid:**
- History ("was originally called logduration")
- Implementation details (HSA hooking, rocprofiler-sdk registration, dh_comms message protocol)
- Alpha/beta disclaimers — this is v1.0

**Tone:** Confident, technical but accessible. Assume the reader knows what GPU kernels
are and has used ROCm, but don't assume they know LLVM or HSA internals.

### Analyzer summary table

Use this structure in the README:

| Analyzer | Description |
|----------|-------------|
| `MemoryAnalysis` | Detects uncoalesced global memory accesses and LDS bank conflicts |
| `Heatmap` | Per-dispatch memory access heatmap by page |
| `BasicBlockAnalysis` | Basic block execution timing with percentile breakdown |
| `AddressLogger` | Raw memory address trace logging |
| `BasicBlockLogger` | Raw basic block timestamp logging |

## Plan of Record

### Micro-steps

1. [x] **Write docs/building-from-source.md** — Gate: accuracy check against source files in Step 1 table
2. [x] **Write docs/container-usage.md** — Gate: accuracy check against source files in Step 2 table
3. [x] **Write docs/usage.md** — Gate: accuracy check against source files in Step 3 table
4. [x] **Rewrite README.md** — Gate: all docs/ pages exist, links resolve, section links to usage.md work
5. [x] **Light edits to existing docs/** — Gate: consistency with new README, env var names updated
6. [x] **Final review pass** — Gate: read through all docs as a new user would; verify all links

### Current Step
All steps complete.

## Design Decisions

### Use future OMNIPROBE_* names, not current LOGDUR_*
The rename refactor will land before or alongside v1.0. Writing docs against the
old names and then rewriting them is wasted work. Write against new names from the start.

### Unified usage.md instead of separate cli-reference.md + analyzers.md
Each option gets its own section with explanation and examples. README.md gives
a brief overview of each option and links directly to the corresponding section
in usage.md (e.g., `docs/usage.md#block-index-filtering`). This gives users a
single place to go for "how do I use feature X?" rather than splitting between
a flag reference and an analyzer guide.

### Container usage as separate doc
Container workflows involve Apptainer-specific commands, two-stage builds, and
filesystem constraints. This is detailed enough to warrant its own page rather
than cluttering the README's install section.

### No docs/ index page
Top-level README links directly to each docs/ page. An index page would just
duplicate those links.

## Open Questions
(All resolved — see Design Decisions and Progress Log.)

## Rejected Approaches
(None yet)

## Progress Log
<!-- Append updates, don't delete -->

### Session 2026-04-07
- Created refactor dossier with proposed README structure and 4 new docs/ pages
- Identified dependency on rf_rename-logduration-to-omniprobe
- User feedback incorporated:
  - Merged cli-reference.md + analyzers.md into single docs/usage.md with per-option sections
  - README brief overview of each option links to its section in usage.md
  - Quick-start uses memory analysis example
  - No docs/README.md index page; top-level README links directly
  - Block index filtering included in usage overview (not hidden as advanced)
- Status: TODO (awaiting user approval to begin work)
- Fleshed out dossier for cold-start self-sufficiency:
  - Added source file reference tables per micro-step (exact files + line ranges + what to extract)
  - Added quick-start sketch with concrete command, representative output, and explanation notes
  - Added README prose guidance (what to emphasize/avoid, tone, analyzer summary table format)

### Session 2026-04-07 (implementation)
- Completed all 6 micro-steps in a single session
- Steps 1–3: Wrote docs/building-from-source.md (179 lines), container-usage.md (161 lines),
  usage.md (339 lines) — each verified against source files listed in dossier
- Step 4: Rewrote README.md (118 lines, down from 178) — CI badges preserved, all docs/ links
  verified, section anchors to usage.md confirmed working
- Step 5: Light edits to existing docs — only 2 heading capitalization fixes needed
  (triton-instrumentation.md, rocblas-maximal-instrumentation.md already clean of LOGDUR_ refs)
- Step 6: Final review — all cross-links verified, no broken anchors, consistent terminology
- Commits: f7012cd, 6765253, 0a2fef6, 524567b, 2d774f0

## Last Verified
Commit: 2d774f0
Date: 2026-04-07

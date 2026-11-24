# Hardware counters per source line (SQTT site markers + SPM)

Omniprobe's analyzers model what instrumented kernels do. This mode measures
it instead: it attributes real hardware counters, such as LDS bank conflicts,
to source lines.

A hardware counter only says how many events happened in a kernel. SPM (the
streaming performance monitor) samples the counters many times while the
kernel runs, and the thread trace (SQTT) with *site markers* records which
source line ran at which moment. `omniprobe --spm` captures both in one
rocprofv3 run, lines them up in time and solves a least-squares fit:

```
Y[w] = sum over lines s of A[w][s] * X[s]
```

`Y[w]` is the counter delta in time window `w` (from SPM), `A[w][s]` how often
line `s` ran in that window (from the markers), and `X[s]` the unknown counter
events per execution of line `s`. With many more windows than lines, `X` is
well determined as long as the lines do not always run in the same ratio.

## Requirements

- **Site markers in the code.** One SQTT marker per instrumented instruction
  (`s_ttracedata`), plus a `.sqtt_funcmap` section mapping marker IDs to source
  lines. Either add them at load time with `--sqtt-sites` (no rebuild; see
  below), or compile with the sqtt-marker LLVM plugin (`SQTT_TRACE_SITES=lds`,
  or `SQTT_TRACE_ADDRESSES=lds`, with `SQTT_SCOPE_CU=-1 SQTT_SCOPE_SIMD=-1` so
  every CU emits markers).
- **rocprof-trace-decoder with the marker API**
  ([ROCm/rocm-systems#13867](https://github.com/ROCm/rocm-systems/pull/13867)).
  Omniprobe finds its Python package and samples from `ROCPROF_TRACE_DECODER_SAMPLES`
  (`<prefix>/share/rocprof-trace-decoder/samples`), `ROCPROF_TRACE_DECODER_LIB`,
  `ROCM_PATH` or `/opt/rocm`.
- **rocprofv3 with SPM** for the GPU. Recent ROCm releases support SPM on
  MI200–MI350; gfx12 needs rocprofiler-sdk built from `develop` and the AMD
  kernel driver (`amdgpu-dkms`), whose compute SPM interface the upstream
  Linux driver does not have.

## Usage

```bash
# Unmodified binary: markers added at load time, one per basic block.
omniprobe --sqtt-sites --per-block -k my_kernel --spm SQ_LDS_BANK_CONFLICT SQ_INSTS_LDS -- ./app    # gfx942
# Code built with the sqtt-marker plugin.
omniprobe --spm SQC_LDS_BANK_CONFLICT SQ_INSTS_LDS -- ./app   # gfx12
```

| Option | Meaning |
|---|---|
| `--sqtt-sites` | Add site markers to GPU code objects as they load (see below). |
| `--per-block` | With `--sqtt-sites`: one marker per basic block instead of per LDS instruction. |
| `--sqtt-relayout` | With `--sqtt-sites`: lay marked kernels out again with the markers inline. |
| `-k REGEX` | With `--sqtt-sites`: only mark kernels whose name matches (no spaces in the regex). |
| `--spm COUNTER ...` | Counters to capture and attribute. Check `rocprofv3 -L` for the names your GPU supports with SPM. |
| `--spm-interval N` | SPM sample interval in shader clock cycles (default 1024). |
| `--samples-per-window N` | SPM samples merged into one fit window (default 2). |
| `--att-shader-engine-mask M` | Shader engines to trace (default all). SPM counts the whole GPU, so trace all of it. |
| `--sqtt-output DIR` | Where the capture and `fit.txt` go (default `omniprobe_sqtt_<timestamp>`). |
| `--rocprofv3 PATH` | rocprofv3 to use. |

The fit can be rerun on an existing capture with
`python3 <omniprobe>/sqtt/counter_fit.py DIR/*.att DIR/*_code_object_id_*.out --spm-json DIR/run_results.json --counter ...`.

Do not interrupt a capture: stopping an SPM capture part way can leave the GPU
in a bad state. omniprobe waits for rocprofv3 on Ctrl+C.

## Site markers without rebuilding (`--sqtt-sites`)

`--sqtt-sites` adds the markers to already-compiled GPU code objects as they
are loaded, so prebuilt libraries and hand-written assembly kernels (e.g.
Tensile, MIOpen) can be measured without a rebuild. It works on gfx9 (e.g.
MI300) and gfx10+ (RDNA). `--sqtt-sites` without `--spm` runs the application
with markers only, e.g. under a profiler started separately.

A rocprofiler-sdk tool (`libsqttSiteInjector.so`) intercepts
`hsa_code_object_reader_create_from_memory` and `_from_file` and runs
`sqtt/sqtt_site_rewrite.py` on each GPU code object:

- **In place (default):** each LDS instruction is replaced by a branch to a stub
  that emits the marker, runs the instruction and branches back. Stubs go in
  padding between functions or after `.text`; distant ones are reached through
  hops. The original code never moves.
- **Relayout** (`--sqtt-relayout`, and automatically when a stub is out of
  reach): the kernel is laid out again after `.text` with the markers inline;
  branches and PC-relative constants are re-aimed and the kernel descriptor
  points at the new code.
- **Per block** (`--per-block`): one marker per basic block, before its first
  LDS instruction; same counts, far cheaper in hot loops.
- Only instructions reachable from kernel entries are marked, following
  computed jumps built from `s_getpc`, so data stored in `.text` is never
  patched. On gfx9 the marker saves M0 in a free SGPR (found by liveness if
  needed) and the kernel's SGPR allocation is raised when required.

It never breaks the application: the rewriter verifies its output (every
changed byte planned, every branch and PC-relative address lands where planned,
ELF layout and kernel descriptors consistent), and the original code object is
loaded whenever anything fails, the rewriter takes longer than
`SQTT_SITE_TIMEOUT` seconds (default 600), or the runtime rejects the result.

Tested: lds_conflict on gfx1201 and gfx942 (output identical in every mode);
MIOpen Winograd convolution (hand-written assembly; verifies in every mode,
0.22 ms unmarked, 0.22 ms with `--per-block`); 15 rocBLAS GEMMs on MI300X with
every loaded code object rewritten (3.57 M sites, zero error). Large libraries
take minutes to rewrite (about 3 minutes for 60 MB), so use `-k`.

## Reading the result

For each counter the fit prints every line (or group of lines), how often it
ran in the trace, and the counter events per execution, plus the share of the
counter the fit leaves unexplained. Lines in the same loop body always run
together and are reported as one group. A counter that counts the marked
instructions themselves (e.g. `SQ_INSTS_LDS` for LDS lines) is a useful sanity
check: it should come out close to 1 per execution.

## Test kernel

`tests/sqtt/lds_conflict.hip` has one conflict-free LDS load (line 61) and one
where all lanes hit the same bank (line 64); early workgroups run mostly the
first and late ones mostly the second. Measured results:

| GPU | Line 64 conflict cycles per execution | Line 61 |
|---|---|---|
| gfx1201 (31 expected) | 30.8–31.4 | about 0 |
| gfx942 (all shader engines traced, three runs) | 29–38 | about 0 |

`tests/sqtt/test_counter_fit.py` tests the fit, the grouping and the SPM
timeline handling without a GPU.

## Notes

- MI300 delivers one SPM stream per XCC, so counter instances sample on
  several timelines; each sample's delta is spread over the windows its own
  interval overlaps.
- The fit assumes the traced work is the work SPM counts; trace all shader
  engines (the default here) and emit markers on every CU.

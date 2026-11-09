# Usage Guide

This page covers every `omniprobe` CLI option in detail. For installation, see
[Building from Source](building-from-source.md) or
[Container Usage](container-usage.md).

## Basic invocation

```bash
omniprobe [options] -- <command>
```

Everything after `--` is the application to instrument. Omniprobe sets up the
runtime environment and then executes `<command>`.

### Minimal example

```bash
# Time all kernel dispatches (no instrumentation, just duration logging)
omniprobe -- ./my_hip_app

# Run with instrumented kernels and memory analysis
omniprobe -i -a MemoryAnalysis -- ./my_hip_app
```

## Analyzers

### Selecting an analyzer (`-a`, `--analyzers`)

```bash
omniprobe -i -a MemoryAnalysis -- ./my_app
omniprobe -i -a Heatmap -- ./my_app
```

You can also pass the path to a custom handler shared library instead of an
analyzer name:

```bash
omniprobe -i -a /path/to/libMyHandler.so -- ./my_app
```

### Available analyzers

| Analyzer | Description | Compile-time plugin | Requires `-i` |
|----------|-------------|-------------------|:---:|
| `MemoryAnalysis` | Detects uncoalesced global memory accesses and LDS bank conflicts | `libAMDGCNSubmitAddressMessages` | Yes |
| `Heatmap` | Per-dispatch memory access heatmap by page | `libAMDGCNSubmitAddressMessages` | Yes |
| `AddressLogger` | Raw memory address trace logging | `libAMDGCNSubmitAddressMessages` | Yes |
| `BasicBlockAnalysis` | Wave entries and active lanes per basic block, at source level (no timing) | `libAMDGCNSubmitBBStart` | Yes |
| `BasicBlockLogger` | Raw basic block timestamp logging | `libAMDGCNSubmitBBStart` | Yes |
| `PythonHandler` | Passes every address and timing message to your own Python module | `libAMDGCNSubmitAddressMessages` | Yes |

Each plugin has `-rocm` and `-triton` variants (e.g.,
`libAMDGCNSubmitAddressMessages-rocm.so`). For HIP applications, use the
`-rocm` variant at compile time. For Triton, the CLI selects the `-triton`
variant automatically.

See [HIP Instrumentation](hip-instrumentation.md) for how to compile HIP
applications with these plugins.

#### MemoryAnalysis

Analyzes global memory access patterns to determine how many L2 cache lines are
actually used versus the minimum needed. Also detects LDS bank conflicts — when
two lanes in a wavefront access different addresses on the same bank, the
accesses serialize.

Output includes two reports:

- **L2 cache line use report**: Shows how many excess cache lines were fetched
  for each source location. High excess indicates strided or scattered access
  patterns that waste memory bandwidth.
- **Bank conflicts report**: Shows LDS bank conflict counts per source location.
  LDS has 32 banks on gfx90a; conflicting accesses are serialized.

Example output:

```
=== L2 cache line use report ======================
No excess cache lines used for global memory accesses
=== End of L2 cache line use report ===============
=== Bank conflicts report =========================
No bank conflicts found
=== End of bank conflicts report ====================
```

When uncoalesced accesses are present, the report shows the source file, line,
and column where they occur, along with the number of excess cache lines.

#### Heatmap

Produces a per-dispatch memory access heatmap showing how many accesses hit
each memory page. The default page size is 1 MB.

Example output:

```
memory heatmap report(simple_kernel(int*, unsigned long) [clone .kd][1])
    page size = 1048576
    page[0x7ff29d200000:7ff29d2fffff] 256 accesses
    page[0x7ff3b4500000:7ff3b45fffff] 256 accesses
```

With `-t json`, one line per dispatch:
`{"kernel": ..., "dispatch_id": N, "kernel_dispatch": K, "page_size": 1048576, "pages": [{"start_address": A, "end_address": B, "accesses": C}, ...]}`
(`end_address` is inclusive).

#### BasicBlockAnalysis

Counts, per basic block, how many times a wave entered it and how many lanes
were active, with the block's source location. No timing; see the
BasicBlockAnalysis JSON schema below.

#### AddressLogger

Logs every memory address message: one record per instrumented memory
instruction executed by a wave. This is the raw trace, for post-processing.
With `-t json`, one object per line with `kernel_name`, `dispatch_id`,
`kernel_dispatch`, `exec`,
`active_lane_count`, `timestamp`, `block_idx_x/y/z`, `wave_num`, `xcc_id`,
`se_id`, `cu_id`, `source_file`, `dwarf_line`, `dwarf_column`, `op_type`
(`read`/`write`/`readwrite`), `memory_space` (`flat`, `global`, `shared`,
`constant`, `scratch`, `gds`; a flat access is reported as the space its
wave's addresses were found in at run time, and as `flat` only when the lanes
disagree), `access_size` (bytes of the accessed type) and
`addresses` (one per active lane, in increasing lane order). The source
location is the instruction's own: code inlined from a header (e.g. HIP's
`blockDim`, a 2-byte `constant` read) points into that header. With CSV
(default) the rows are `ADDRESS_MESSAGE,...` under a header line; its columns
`dispatch,kernel_dispatch` are the two numbers described under
[Dispatch capture](#dispatch-capture).

#### BasicBlockLogger

Logs one record per wave per basic block entered, with a timestamp. Same JSON
fields as AddressLogger minus the address fields, plus `basic_block_id` (the
id BasicBlockAnalysis reports; `user_data` carries the same value). CSV rows
are `WAVE_MESSAGE,...`.

> **Note**: `BasicBlockLogger` and `BasicBlockAnalysis` require the
> `libAMDGCNSubmitBBStart` plugin (use `-rocm.so` for HIP, `-triton.so` for
> Triton).

#### PythonHandler

Runs an analysis written in Python, without writing a C++ handler plugin. Name
the module in `OMNIPROBE_PYTHON_HANDLER`, either as a path to a `.py` file or
as a module name importable through `PYTHONPATH`:

```bash
OMNIPROBE_PYTHON_HANDLER=./my_analysis.py omniprobe -i -a PythonHandler -- ./my_app
```

The module defines any of the following functions; at least one of the first
three is required. Each receives one `dict`, and every dict has `kernel` (str),
`dispatch_id` (int) and `kernel_dispatch` (int, see [Dispatch capture](#dispatch-capture)):

| Function | Called |
|----------|--------|
| `handleAddressWave(msg)` | once per wave per instrumented memory instruction (recommended) |
| `handleAddressMessage(msg)` | once per active lane of each instrumented memory instruction; only key `address` (int). The original interface, kept as is |
| `handleTimeMessage(msg)` | once per time-interval message |
| `handleReport(msg)` | once per dispatch, after its last message; no further keys |

`handleAddressWave` keys:

| Key | Meaning |
|-----|---------|
| `addresses` | list of int, one per active lane, in increasing lane order |
| `lanes` | list of int, the lane id of each address (the set bits of `exec`) |
| `exec` | int, the wave's 64-bit execution mask |
| `access_type` | `"read"`, `"write"`, `"readwrite"` or `"undefined"` |
| `memory_space` | `"global"`, `"shared"` (LDS), `"scratch"`, `"constant"`, `"gds"`, or `"flat"` when the wave's lanes pointed into different spaces |
| `access_size` | bytes of the accessed type |
| `source_file`, `line`, `column` | source location of the instruction (its own, so possibly a header for inlined code) |
| `block_idx` | (x, y, z) workgroup index |
| `wave_num`, `cu_id`, `se_id`, `xcc_id` | which wave, and where it ran |
| `timestamp` | int, `s_memtime` ticks when the wave sent the message |

`handleTimeMessage` keys: `start`, `stop`, `elapsed_time` (`stop - start`, in
`s_memtime` ticks), `block_id` (the instrumentation's tag; the basic block index
for BBInterval), plus the same wave keys (`exec`, `source_file`, `line`,
`column`, `block_idx`, `wave_num`, `cu_id`, `se_id`, `xcc_id`, `timestamp`).

There is one interpreter per process and the module is imported once, so
module-level state persists across dispatches; use `handleReport` to emit
per-dispatch results (keyed by `dispatch_id`). Calls come from several threads
(one per in-flight dispatch) but hold the GIL, so they never run at the same
time. Cost is roughly 10 µs per call, so `handleAddressWave` (one call per wave) is
up to 64 times cheaper than `handleAddressMessage` (one per lane); for full
applications, narrow with `-k` and `-d`. If the module cannot be imported or
lacks a required function, an error is printed and the dispatch runs with the
default handlers instead. Only this plugin links libpython.

See `tests/python_handler/wave_handler.py` (per wave) and `tests/python_handler/stress_handler.py` (per lane) for complete examples.

**When the application is itself Python** (Triton, PyTorch, a ctypes program),
the handler module is imported into the application's interpreter and shares
its GIL. This works, including back-to-back Triton launches, and at exit
the application waits for the last dispatches' handlers before its interpreter
shuts down. One pattern cannot work: an application that **holds the GIL while
it waits for an instrumented kernel**, for example a C extension that launches
and synchronizes without releasing the GIL (`ctypes.PyDLL`). A kernel that
sends many messages waits for the handler to drain them, and the handler waits
for the GIL. After 10 s omniprobe prints
`omniprobe: WARNING: PythonHandler has waited 10 s for the Python GIL` and the
run does not finish; release the GIL around the blocking call (`ctypes.CDLL`
does), or use a C++ handler. A Python thread that keeps running bytecode while
kernels execute slows the handler down, because every handler call waits for
its turn at the GIL. The plugin is built against one Python version (the one
CMake found); a host running a different version has been seen to work but is
not supported.

## Instrumented mode

### Enabling instrumentation (`-i`, `--instrumented`)

```bash
omniprobe -i -a MemoryAnalysis -- ./my_app
```

When `-i` is set, Omniprobe swaps original kernel dispatches for their
instrumented clones at runtime. Instrumented kernels contain additional
instructions that stream memory access or timing data to the host.

For HIP applications, the instrumented clones must already exist in the
binary — this requires compiling with an Omniprobe LLVM plugin. See
[HIP Instrumentation](hip-instrumentation.md) for details. For Triton,
instrumentation happens automatically during JIT compilation.

Without `-i`, Omniprobe still intercepts dispatches for basic timing, but does
not run the instrumented kernel variants.

## Kernel filtering

### Selecting kernels (`-k`, `--kernels`)

```bash
# Only instrument kernels matching a regex
omniprobe -i -a MemoryAnalysis -k "matmul" -- ./my_app

# Match multiple patterns
omniprobe -i -a MemoryAnalysis -k "matmul|gemm" -- ./my_app
```

The filter is an [ECMAScript regular expression](https://en.cppreference.com/w/cpp/regex/ecmascript)
*searched* in the demangled kernel name, so `-k gpuMain` selects `gpuMain2`,
`gpuMain3_interior`, and so on. Only instrumented kernels whose names match will
be dispatched; all others run their original (uninstrumented) version and are
logged as `Kernel filter excluded <name>`.

The demangled name is the one in those log lines, e.g. `void gpuMain2<4>(double,
...)` for a template, `(anonymous namespace)::f(int*)`, or `f(int*) [clone
.intern] ...` for a static kernel. Anchor with care: `^gpuMain2` does not match
the template above, because its name starts with its return type. If no
dispatched kernel matches, the run ends with `omniprobe: WARNING: no dispatched
kernel matched the kernel filter -k '...'` and the names it could have matched,
which is different from kernels having no instrumented clone.

Filtering does not cost you source-line attribution. Kernels are indexed for the kernel
database regardless of the filter, so a filtered run reports source file, line and column
for the kernels it does instrument. Earlier versions tied the two together, which meant a
filter had to name a kernel that was actually dispatched — and that kernel's own data was
sacrificed — before any other kernel could be correlated to source.

Requires `-i`.

## Dispatch capture

`-d`/`--dispatches` selects which dispatches of each kernel run instrumented.
Dispatches are numbered **per kernel, from 1**: the 5th dispatch of `kernel_a`
is `kernel_a`'s 5th launch, however many other kernels ran in between. With
`-k`, the numbering applies to each kernel the regex matches: `-k 'A|B' -d 2,5`
instruments the 2nd and 5th dispatch of A and of B. Without `-k`, every kernel
has its own count, so `-d 1` is the first dispatch of each kernel. Every
dispatch of a kernel counts, whether it ran instrumented or not.

```bash
omniprobe -i -a MemoryAnalysis -- ./my_app                 # all dispatches (default; same as -d all)
omniprobe -i -a MemoryAnalysis -d 1 -- ./my_app            # first dispatch of each kernel
omniprobe -i -a MemoryAnalysis -d 2,5 -- ./my_app          # 2nd and 5th
omniprobe -i -a MemoryAnalysis -d 1-10 -- ./my_app         # 1st to 10th (inclusive)
omniprobe -i -a MemoryAnalysis -d 10- -- ./my_app          # 10th and every later one
omniprobe -i -a MemoryAnalysis -d 1,3,4:3 -- ./my_app      # 1,3,4,5,7,8,9,11,12
omniprobe -i -a MemoryAnalysis -d 1,3,4:3:100 -- ./my_app  # 1,3,4,101,103,104,201,203,204
omniprobe -i -a MemoryAnalysis -d 1,3,4::100 -- ./my_app   # 1,3,4,101,103,104,201,... without end
omniprobe -i -a MemoryAnalysis -d 1::100 -- ./my_app       # every 100th: 1,101,201,...
```

Grammar: `all`, or `pattern[:count[:stride]]`.

| Part | Meaning |
|------|---------|
| `pattern` | comma-separated items: `N`, an inclusive range `A-B`, or an open range `A-` (the A-th dispatch and every later one). Order and duplicates do not matter. |
| `count` | how many copies of the pattern, **including the first**. Empty (`1,3::100`, `1,3:`) repeats without end. Default 1. |
| `stride` | distance between copies, measured from the first. Default: one past the pattern's span (`max - min + 1`), so the next copy starts right after the last item: `1,3,4:3` = 1,3,4, 5,7,8, 9,11,12. |

Copies may overlap (`1-10:3:5` = 1–20); an open range cannot be repeated.
Numbers start at 1. Spaces are not allowed anywhere in a spec. A malformed spec
stops omniprobe before the application starts (exit status 2), naming the
problem.

**Brackets and the shell.** `[1,3,4:3]` is accepted, but only quoted:
`-d '[1,3,4:3]'`. Unquoted, `[...]` is a shell glob: bash replaces `[1,3,4]`
with `1` if the current directory holds a file called `1` (measured), and zsh
stops with `no matches found`. The forms without brackets need no quoting.

Output reports both numbers: `dispatch_id` counts all dispatches of the process
together (as before), `kernel_dispatch` is the per-kernel number `-d` uses. Find
the number to pass to `-d` in a first run's `kernel_dispatch` field, or on the
`Found instrumented alternative for <kernel> (dispatch N, kernel dispatch K)`
line.

**Several GPUs and threads.** A kernel's dispatches on all GPUs of one process
share one count, so on a multi-GPU process `-d 1` is the kernel's first dispatch
overall, not the first on each GPU (it was per GPU before `-d` took dispatch
numbers). When several threads launch the same kernel concurrently, which
launch is "the n-th" is decided by the order omniprobe intercepts them and is
not deterministic from run to run. Each process (each MPI rank, say) counts its
own dispatches from 1.

`-d random` (each dispatch with probability 1/100) was removed; for sampling use
`-d 1::100`, every 100th dispatch of each kernel.

Requires `-i`.

## Output format and location

### Output format (`-t`, `--log-format`)

```bash
omniprobe -i -a AddressLogger -t csv -- ./my_app
omniprobe -i -a AddressLogger -t json -- ./my_app
```

| Format | Description |
|--------|-------------|
| `csv` | Comma-separated values (default) |
| `json` | Structured JSON (see schemas below) |

#### MemoryAnalysis JSON schema

When using `-a MemoryAnalysis -t json`, each dispatch produces an object with
a flat `accesses` array. Multiple dispatches are wrapped in a JSON array.

```json
{
  "kernel": "my_kernel",
  "dispatch_id": 1,
  "kernel_dispatch": 1,
  "accesses": [
    {
      "source_file": "/path/to/source.hip",
      "line": 42,
      "column": 5,
      "memory_space": "global",
      "access_type": "read",
      "execution_count": 1024,
      "ir_bytes": 4,
      "isa_bytes": 16,
      "isa_instruction": "global_load_dwordx4",
      "cache_lines_needed": 2,
      "cache_lines_used": 5,
      "excess_cache_lines": 3,
      "bank_conflicts": 0
    }
  ],
  "metadata": {
    "version": "...",
    "timestamp": "...",
    "gpu_info": { "architecture": "gfx90a", "cache_line_size": 128 }
  }
}
```

| Field | Description |
|-------|-------------|
| `source_file` | Source file path from DWARF info |
| `line`, `column` | Source location |
| `memory_space` | `"global"` or `"lds"` |
| `access_type` | `"read"`, `"write"`, or `"read/write"` |
| `execution_count` | Number of times this access was observed |
| `excess_cache_lines` | Extra L2 cache lines fetched beyond the minimum needed (global only) |
| `bank_conflicts` | Total LDS bank conflicts observed (LDS only) |
| `cache_lines_needed`, `cache_lines_used` | Summed over executions; their difference is `excess_cache_lines` |
| `ir_bytes`, `isa_bytes`, `isa_instruction` | Accessed type size, bytes the ISA instruction moves, and that instruction |

Accesses through *flat* pointers (all accesses at `-O0`, CMake's Debug default,
and any access through a pointer loaded from memory) are classified at run
time: the instrumentation checks, per wave, whether every active lane's address
is in LDS, in scratch, or in neither (global), and the access is analyzed as
such. So `-O0` and optimized builds give the same findings. Each dispatch
object also has `unanalyzed_flat_accesses`: wave-level flat accesses whose
lanes pointed into *different* address spaces, which are counted but not
analyzed. A line on stderr reports the count per dispatch. (Binaries
instrumented before this classification existed report all flat accesses
here; re-instrument them.) Likewise `unattributed_accesses` counts global
accesses dropped because no ISA instruction was found for their source line:
all of them when the binary was built without `-g` (DWARF line info is how
accesses are matched to instructions), so build with `-g`.

LDS bank conflicts depend on the DS instruction, not only on the access size:
on gfx950, `ds_read_b64`/`ds_read_b128` see 64 banks while other LDS accesses
see 32, and `ds_read2`/`ds_write2` serve each address separately. On gfx950 the
analysis takes the instruction from the code object (each LDS entry has
`isa_instruction` and `isa_bytes`). When the compiler merges several accesses
into one instruction, the access whose source location the instruction
carries counts its conflicts; the others are counted in `merged_lds_accesses`.
LDS atomics (`atomicAdd` etc. on `__shared__` data) are analyzed on gfx950:
lanes of a wave updating the *same* address conflict too (atomics are not
broadcast), except where the compiler combined a uniform-address atomic into
one lane's update. Float atomics (`ds_add_f32`, `ds_pk_add_f16`) are served one
lane at a time; that cost is not a bank conflict, and the entry reports it as
`serialized_lanes` (active lanes summed over executions) instead.

#### BasicBlockAnalysis JSON schema

BasicBlockAnalysis needs a binary instrumented with the BBStart plugin
(`-fpass-plugin=<omniprobe>/lib/plugins/libAMDGCNSubmitBBStart-rocm.so`). On a
binary built with another plugin it warns once and reports no blocks. When
`-t json` is used, each dispatch produces an object with a `basic_blocks`
array:

```json
{
  "kernel": "my_kernel",
  "dispatch_id": 1,
  "kernel_dispatch": 1,
  "basic_blocks": [
    {
      "basic_block_id": 4,
      "source_file": "/path/to/source.hip",
      "line": 19,
      "column": 19,
      "wave_visits": 80,
      "active_lanes": 5120
    }
  ]
}
```

| Field | Description |
|-------|-------------|
| `basic_block_id` | The BBStart plugin's number for the block: its position among the instrumented kernel's LLVM IR basic blocks. Stable for a given binary, so identical runs give identical ids. The plugin prints the id-to-location mapping at compile time ("Injecting Basic Block tracker N ..."). |
| `source_file`, `line`, `column` | Source location of the first instruction in the block that has one, followed through inlining to the call site in the kernel itself. |
| `wave_visits` | How many times a wave entered the block, summed over all waves. A loop body run T times by W waves gives T×W. |
| `active_lanes` | Active lanes summed over those entries (popcount of the exec mask at block entry). `active_lanes / wave_visits` is the mean number of active lanes per entry; below the wave size it indicates divergence or partially filled waves. |

Blocks no wave entered are not listed. IR blocks are not ISA blocks: the
compiler may merge, split or duplicate them, so the ids do not correspond to
blocks in the disassembly.

**No timing.** Earlier versions reported `min_cycles`, `max_cycles` and
percentiles. Those were intervals between consecutive instrumentation messages
of a wave, dominated by the cost of the instrumentation itself (waiting for the
shared message buffer and for the host to drain it): on one kernel the median
went from about 25 thousand to 4 to 24 million cycles when the grid grew from
16 to 4096 waves. They have been removed rather than kept as a misleading
measure of per-block cost. Use the counts to find frequently executed and
divergent blocks, and rocprofv3 or hardware counters for time.

### JSON output file (`-o`, `--output`)

```bash
# Auto-generate timestamped file (results_yyyy-mm-dd_hhmmss.json)
omniprobe -i -a MemoryAnalysis -t json -- ./my_app

# Specify output file explicitly
omniprobe -i -a MemoryAnalysis -t json -o results.json -- ./my_app
```

When `-t json` is active and no `-l` is provided, omniprobe automatically
writes results to a file:

- If `-o FILE` is given, results are written to that path.
- If `-o` is omitted, a timestamped file (`results_yyyy-mm-dd_hhmmss.json`)
  is generated in the current directory.

The output path is printed after the run completes. Ignored when `-t csv`.

### Output location (`-l`, `--log-location`)

```bash
# Write to console (default)
omniprobe -i -a AddressLogger -- ./my_app

# Write to file
omniprobe -i -a AddressLogger -l output.csv -- ./my_app
```

Default is `console` (stdout). Primarily used for CSV output. When `-t json`
is active, prefer `-o` instead.

### Output streams

omniprobe forwards the instrumented application's stdout to its own stdout and
the application's stderr to its own stderr, line by line and unchanged. Analysis
handlers run inside the application, so their console reports (the default
`-l console`) appear on **stdout**; omniprobe's and the interceptor's own
messages (e.g. "Found instrumented alternative", warnings, the end-of-run
summary of kernels that ran without an instrumented clone) are on **stderr**.
A handler plugin that writes to `std::cout` or `printf` therefore reaches the
user's stdout.

## Block index filtering

### Filtering by block index (`--filter-x`, `--filter-y`, `--filter-z`)

```bash
# Only capture messages from block (0, 0, 0)
omniprobe -i -a MemoryAnalysis --filter-x 0 --filter-y 0 --filter-z 0 -- ./my_app

# Capture blocks with x index in range [10, 20)
omniprobe -i -a MemoryAnalysis --filter-x 10:20 -- ./my_app
```

Each filter accepts either a single index `N` or a half-open range `N:M`
(includes `N`, excludes `M`). Only instrumentation messages from blocks matching
all specified filters are processed; messages from other blocks are silently
dropped.

This is useful for focusing analysis on a specific region of the grid when the
full kernel has too many blocks to analyze efficiently.

## Library filtering

### Filtering libraries (`--library-filter`)

```bash
omniprobe -i -a MemoryAnalysis --library-filter filter.json -- ./my_app
```

The filter file is a JSON configuration that controls which GPU code objects are
instrumented at runtime:

```json
{
    "include": ["**/rocblas/**"],
    "include_with_deps": ["**/hipblaslt/**"],
    "exclude": ["**/miopen/**"]
}
```

| Field | Description |
|-------|-------------|
| `include` | Paths to include (glob patterns with `*` and `**`) |
| `include_with_deps` | Include paths and their runtime-loaded dependencies |
| `exclude` | Paths to exclude (always wins over include) |

This is primarily used when instrumenting pre-compiled GPU libraries like
rocBLAS or hipBLASLt. See [rocBLAS Maximal Instrumentation](rocblas-maximal-instrumentation.md)
for a detailed walkthrough.

## Triton instrumentation

### Triton cache (`-c`, `--cache-location`)

```bash
omniprobe -i -a MemoryAnalysis -c ~/.triton/cache -- python my_triton_script.py
```

When instrumenting Triton kernels, pass the Triton cache directory. Omniprobe
reads the cached kernel bitcode, instruments it, and writes instrumented
variants back to the cache. Triton then loads the instrumented versions on the
next run.

### Instrumentation scope (`--instrumentation-scope`)

```bash
# Only instrument code from a specific file
omniprobe -i -a MemoryAnalysis -c ~/.triton/cache \
    --instrumentation-scope "matmul.py" -- python my_triton_script.py

# Instrument specific lines
omniprobe -i -a MemoryAnalysis -c ~/.triton/cache \
    --instrumentation-scope "matmul.py:42,50:60" -- python my_triton_script.py
```

Format: `file[:line_spec,...][;file[:line_spec,...]]`

Line specs can be a single line `N` or a range `N:M`. Multiple files are
separated by `;`.

### Instrumentation scope file (`--instrumentation-scope-file`)

```bash
omniprobe -i -a MemoryAnalysis -c ~/.triton/cache \
    --instrumentation-scope-file scope.txt -- python my_triton_script.py
```

Same syntax as `--instrumentation-scope`, one entry per line. Blank lines and
lines starting with `#` are ignored.

For detailed Triton usage, see [Triton Instrumentation](triton-instrumentation.md).

> **Note**: Scoped instrumentation also works for HIP applications, but it must
> be applied at compile time by setting the `INSTRUMENTATION_SCOPE` or
> `INSTRUMENTATION_SCOPE_FILE` environment variables before running `hipcc`.
> The `--instrumentation-scope` CLI flag only works for Triton (where Omniprobe
> controls JIT compilation). See
> [HIP Instrumentation — Scoped instrumentation](hip-instrumentation.md#scoped-instrumentation).

## Diagnostic options

### Verbose output (`-v`, `--verbose`)

```bash
omniprobe -v -i -a MemoryAnalysis -- ./my_app
```

Prints additional information about kernel discovery, dispatch interception,
and handler setup.

### Environment dump (`-e`, `--env-dump`)

```bash
omniprobe -e -i -a MemoryAnalysis -- ./my_app
```

Prints all environment variables set by Omniprobe before launching the
application. Useful for debugging configuration issues.

## Environment variables

The `omniprobe` CLI sets these environment variables automatically based on
command-line flags. You normally don't need to set them directly, but they are
documented here for debugging and advanced use cases.

> **Note**: The current codebase uses `LOGDUR_*` names for these variables.
> They will be renamed to `OMNIPROBE_*` in an upcoming release.

| Variable | CLI flag | Description |
|----------|----------|-------------|
| `OMNIPROBE_INSTRUMENTED` | `-i` | Enable instrumented kernel dispatch |
| `OMNIPROBE_HANDLERS` | `-a` | Comma-separated list of handler library paths |
| `OMNIPROBE_LOG_FORMAT` | `-t` | Output format (`csv` or `json`) |
| `OMNIPROBE_LOG_LOCATION` | `-l` | Output file path, or `console` |
| `OMNIPROBE_FILTER` | `-k` | ECMAScript regex for kernel name filtering |
| `OMNIPROBE_DISPATCHES` | `-d` | Dispatch spec, as for `-d` (brackets removed). A malformed value set by hand instruments no dispatch and is reported as an error |
| `OMNIPROBE_KERNEL_CACHE` | `-c` | Triton kernel cache directory |
| `OMNIPROBE_LIBRARY_FILTER` | `--library-filter` | Path to library filter JSON config |
| `DH_COMMS_GROUP_FILTER_X` | `--filter-x` | Block index filter for X dimension |
| `DH_COMMS_GROUP_FILTER_Y` | `--filter-y` | Block index filter for Y dimension |
| `DH_COMMS_GROUP_FILTER_Z` | `--filter-z` | Block index filter for Z dimension |
| `INSTRUMENTATION_SCOPE` | `--instrumentation-scope` | Compile-time scope filter (Triton) |
| `INSTRUMENTATION_SCOPE_FILE` | `--instrumentation-scope-file` | Scope filter file (Triton) |
| `ROCM_PATH` | — | ROCm whose `llvm/bin/llvm-objdump` kernelDB runs (source attribution). If unset or lacking it, the CLI picks, in order: the ROCm `liblogDuration64.so` links against, `hipconfig --rocmpath`, `rocminfo`/`hipcc` on `PATH`, `/opt/rocm-*`, `/opt/rocm`; an instrumented run with none of them is an error |
| `OMNIPROBE_PYTHON_HANDLER` | — | Python module for `-a PythonHandler` (set by you; see PythonHandler) |

Configuration errors end the run with `omniprobe: ERROR: ...` and exit status 1
before the application runs: an unknown analyzer name, a handler plugin that
does not exist, cannot be loaded or has no `getMessageHandlers`, and a
`PythonHandler` module that is unset, cannot be imported, or defines none of
the handler functions.

## Python API

Omniprobe includes a Python API module for programmatic access to analysis
results. The API invokes the CLI with `-t json -o <tempfile>` under the hood,
reads the JSON output file, and parses it into structured dataclasses.

### Quick example

```python
from omniprobe.api import Omniprobe

op = Omniprobe()  # finds omniprobe on PATH, else the launcher next to the package

# Memory analysis
result = op.analyze_memory("./my_hip_app", kernel_filter="matmul")
for kernel in result.kernels:
    for access in kernel.accesses:
        if access.excess_cache_lines > 0:
            print(f"{access.source_file}:{access.line} — "
                  f"{access.excess_cache_lines} excess cache lines")
if result.uninstrumented_kernels:
    print("partial result, not instrumented:", result.uninstrumented_kernels)

# Basic block analysis
bb_result = op.analyze_basic_blocks("./my_hip_app")
for kernel in bb_result.kernels:
    for bb in kernel.basic_blocks:
        print(f"BB {bb.bb_id} {bb.source_file}:{bb.line}: "
              f"{bb.wave_visits} wave visits, {bb.active_lanes} active lanes")

# Raw address trace, first 10000 records only
trace = op.log_addresses("./my_hip_app", max_records=10000)
```

### API reference

All analysis methods take `(command, kernel_filter=None, dispatches="all")`,
where `dispatches` is a `-d` spec (see [Dispatch capture](#dispatch-capture)); a
malformed one raises `DispatchSpecError`, a `ValueError`, before anything runs.
Every per-dispatch result has `dispatch_id` and `kernel_dispatch`;
the two trace methods also take `max_records=None`. Every result has
`uninstrumented_kernels: dict[str, int]` (kernel name → dispatches that ran
without an instrumented clone and are therefore missing from the result).

**`Omniprobe(omniprobe_path=None)`** — Constructor. Uses an explicit path,
else `omniprobe` on `PATH`, else the launcher shipped next to the package
(install tree `<prefix>/omniprobe/bin/omniprobe`). Raises `FileNotFoundError`
if none exists.

**`analyze_memory(...)`** → `MemoryAnalysisResult`: per kernel dispatch
(`KernelMemoryResult`: `kernel_name`, `dispatch_id`, `accesses`,
`unanalyzed_flat_accesses`, `unattributed_accesses`), each `MemoryAccess` with `source_file`, `line`,
`column`, `memory_space`, `access_type`, `execution_count`,
`excess_cache_lines`, `bank_conflicts`, `cache_lines_needed`,
`cache_lines_used`, `isa_instruction`, `ir_bytes`, `isa_bytes`.
AddressMessages binary.

**`analyze_basic_blocks(...)`** → `BasicBlockResult` with per-kernel
`basic_blocks` containing `bb_id`, `source_file`, `line`, `column`,
`wave_visits` and `active_lanes` (see the BasicBlockAnalysis JSON schema).
BBStart binary.

**`analyze_heatmap(...)`** → `HeatmapResult`: per dispatch `KernelHeatmap`
(`kernel_name`, `dispatch_id`, `page_size`, `pages`), each `HeatmapPage`
with `start_address`, `end_address` (inclusive), `accesses`. AddressMessages
binary.

**`log_addresses(..., max_records=None)`** → `AddressTrace(records,
truncated)`, each `AddressRecord` with `kernel_name`, `dispatch_id`,
`timestamp`, `exec_mask`, `active_lane_count`, `block_idx` (x, y, z),
`wave_num`, `xcc_id`, `se_id`, `cu_id`, `op_type`, `memory_space`,
`access_size`, `source_file`, `line`, `column`, `addresses` (one per active
lane, increasing lane order). The trace file is parsed as a stream: with
`max_records` at most that many records are kept and `truncated` says whether
more followed. AddressMessages binary.

**`log_basic_blocks(..., max_records=None)`** → `BasicBlockTrace(records,
truncated)`, each `BBRecord` with the same wave fields plus `basic_block_id`,
`source_file`, `line`, `column`. BBStart binary.

### Error handling

| Exception | Condition |
|-----------|-----------|
| `FileNotFoundError` | `omniprobe` binary not found |
| `RuntimeError` | Non-zero exit code (includes stderr) |
| `ValueError` | Malformed JSON output |

### Module location

The API lives at `omniprobe/api/` in the source tree and is installed to
`<prefix>/omniprobe/api/`. Put the repository root (source tree) or `<prefix>`
(install tree) on `PYTHONPATH` and `from omniprobe.api import Omniprobe`
works; in the install tree no `PATH` setting is needed either.

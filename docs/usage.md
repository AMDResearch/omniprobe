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

| Analyzer | Description | Requires `-i` |
|----------|-------------|:---:|
| `MemoryAnalysis` | Detects uncoalesced global memory accesses and LDS bank conflicts | Yes |
| `Heatmap` | Per-dispatch memory access heatmap by page | Yes |
| `BasicBlockAnalysis` | Basic block execution timing with percentile breakdown | Yes |
| `AddressLogger` | Raw memory address trace logging | Yes |
| `BasicBlockLogger` | Raw basic block timestamp logging | Yes |

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

#### BasicBlockAnalysis

Tracks execution time of each basic block per wave (wavefront). After the kernel
completes, reports timing statistics including min, max, and percentile
breakdowns. Also maps which compute units each wave ran on.

Useful for identifying hot basic blocks or uneven workload distribution across
compute units.

#### AddressLogger

Logs all memory address messages to output in CSV or JSON format. This is the
raw trace — useful when you want to post-process the data yourself rather than
use one of the higher-level analyzers.

#### BasicBlockLogger

Logs raw basic block entry timestamps. Like AddressLogger, this produces the raw
trace for custom post-processing.

> **Note**: `BasicBlockLogger` and `BasicBlockAnalysis` require a Triton-specific
> LLVM plugin (`libAMDGCNSubmitBBStart-triton.so`) and only work with Triton
> kernels.

## Instrumented mode

### Enabling instrumentation (`-i`, `--instrumented`)

```bash
omniprobe -i -a MemoryAnalysis -- ./my_app
```

When `-i` is set, Omniprobe swaps original kernel dispatches for their
instrumented clones at runtime. Instrumented kernels contain additional
instructions that stream memory access or timing data to the host.

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
matched against the kernel name. Only instrumented kernels whose names match will
be dispatched; all others run their original (uninstrumented) version.

Requires `-i`.

## Dispatch capture

### Selecting dispatches (`-d`, `--dispatches`)

```bash
# Instrument all dispatches (default)
omniprobe -i -a MemoryAnalysis -d all -- ./my_app

# Instrument only the first dispatch of each kernel
omniprobe -i -a MemoryAnalysis -d 1 -- ./my_app

# Randomly select one dispatch per kernel
omniprobe -i -a MemoryAnalysis -d random -- ./my_app
```

| Value | Behavior |
|-------|----------|
| `all` | Instrument every dispatch (default) |
| `1` | Only the first dispatch of each kernel |
| `random` | Randomly select one dispatch per kernel |

Instrumenting all dispatches gives the most complete picture but adds overhead.
For large workloads, `1` or `random` can significantly reduce runtime while
still catching representative behavior.

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
| `json` | JSON format |

### Output location (`-l`, `--log-location`)

```bash
# Write to console (default)
omniprobe -i -a AddressLogger -- ./my_app

# Write to file
omniprobe -i -a AddressLogger -l output.csv -- ./my_app
```

Default is `console` (stdout).

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
| `OMNIPROBE_DISPATCHES` | `-d` | Dispatch capture mode (`all`, `random`, or `1`) |
| `OMNIPROBE_KERNEL_CACHE` | `-c` | Triton kernel cache directory |
| `OMNIPROBE_LIBRARY_FILTER` | `--library-filter` | Path to library filter JSON config |
| `DH_COMMS_GROUP_FILTER_X` | `--filter-x` | Block index filter for X dimension |
| `DH_COMMS_GROUP_FILTER_Y` | `--filter-y` | Block index filter for Y dimension |
| `DH_COMMS_GROUP_FILTER_Z` | `--filter-z` | Block index filter for Z dimension |
| `INSTRUMENTATION_SCOPE` | `--instrumentation-scope` | Compile-time scope filter (Triton) |
| `INSTRUMENTATION_SCOPE_FILE` | `--instrumentation-scope-file` | Scope filter file (Triton) |

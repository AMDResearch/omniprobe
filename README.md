# Omniprobe

[![Triton Version Staleness Check](https://github.com/AMDResearch/omniprobe/actions/workflows/triton-staleness-check.yml/badge.svg)](https://github.com/AMDResearch/omniprobe/actions/workflows/triton-staleness-check.yml)
[![Build Toolchain Image](https://github.com/AMDResearch/omniprobe/actions/workflows/toolchain-image.yml/badge.svg)](https://github.com/AMDResearch/omniprobe/actions/workflows/toolchain-image.yml)
[![Build](https://github.com/AMDResearch/omniprobe/actions/workflows/build.yml/badge.svg)](https://github.com/AMDResearch/omniprobe/actions/workflows/build.yml)

Omniprobe instruments HIP and Triton GPU kernels to pinpoint performance
bottlenecks at the source-line level. Unlike profilers that report per-dispatch
aggregate metrics, Omniprobe injects analysis code *inside* kernels at compile
time, streaming detailed observations to the host while the kernel runs.

No source code changes are required for HIP kernels — instrumentation happens
automatically at the LLVM IR level. Instrumented kernel clones are swapped in
transparently at dispatch time.

Key capabilities:

- **Uncoalesced memory access detection** — find global memory accesses that
  waste L2 cache lines
- **LDS bank conflict detection** — identify shared memory accesses that
  serialize across banks
- **Memory access heatmaps** — visualize per-page access frequency
- **Basic block timing** — measure execution time at basic block granularity
  with percentile breakdowns

## Quick Start

```bash
# Build (see docs/building-from-source.md for full instructions)
cmake -B build -DROCM_PATH=/opt/rocm -DCMAKE_HIP_ARCHITECTURES=gfx90a \
    -DCMAKE_INSTALL_PREFIX=$PWD/install -DINTERCEPTOR_BUILD_TESTING=ON
cmake --build build -j$(nproc)

# Run memory analysis on a test kernel
LD_LIBRARY_PATH=$PWD/build:$LD_LIBRARY_PATH \
    omniprobe -i -a MemoryAnalysis -- ./build/tests/test_kernels/simple_memory_analysis_test
```

Example output:

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

"Found instrumented alternative" means Omniprobe auto-swapped the original
kernel for its instrumented clone. The reports summarize memory access
efficiency. In real-world code with strided or scattered access patterns, the
L2 report flags excess cache line usage with source locations.

## Installation

**From source**: Requires ROCm (7.0+), CMake 3.15+, and a C++20 compiler.
See [docs/building-from-source.md](docs/building-from-source.md) for the full
build and install workflow.

**Container**: Docker and Apptainer images are provided with all dependencies
pre-installed. See [docs/container-usage.md](docs/container-usage.md), or just
run:

```bash
./containers/run-container.sh --docker   # or --apptainer
```

## Usage Overview

```bash
omniprobe [options] -- <command>
```

See [docs/usage.md](docs/usage.md) for the complete reference with examples.

| Option | Description | Details |
|--------|-------------|---------|
| `-a`, `--analyzers` | Which analysis to run | [Analyzers](docs/usage.md#analyzers) |
| `-i`, `--instrumented` | Enable instrumented kernel dispatch | [Instrumented mode](docs/usage.md#instrumented-mode) |
| `-k`, `--kernels` | Regex to select which kernels to instrument | [Kernel filtering](docs/usage.md#kernel-filtering) |
| `-d`, `--dispatches` | Which dispatches to capture (`all`, `random`, `1`) | [Dispatch capture](docs/usage.md#dispatch-capture) |
| `-t`, `--log-format` | Output format (`csv`, `json`) | [Output format](docs/usage.md#output-format-and-location) |
| `-l`, `--log-location` | Output file or `console` | [Output location](docs/usage.md#output-format-and-location) |
| `--filter-x/y/z` | Block index filtering (`N` or `N:M` range) | [Block filtering](docs/usage.md#block-index-filtering) |
| `--library-filter` | JSON config for library include/exclude | [Library filtering](docs/usage.md#library-filtering) |
| `-c`, `--cache-location` | Triton kernel cache directory | [Triton cache](docs/usage.md#triton-instrumentation) |
| `--instrumentation-scope` | Limit instrumentation to specific source locations | [Scope](docs/usage.md#triton-instrumentation) |

## Analyzers

| Analyzer | Description |
|----------|-------------|
| `MemoryAnalysis` | Detects uncoalesced global memory accesses and LDS bank conflicts |
| `Heatmap` | Per-dispatch memory access heatmap by page |
| `BasicBlockAnalysis` | Basic block execution timing with percentile breakdown |
| `AddressLogger` | Raw memory address trace logging |
| `BasicBlockLogger` | Raw basic block timestamp logging |

See [docs/usage.md#analyzers](docs/usage.md#analyzers) for details on each.

## Instrumenting HIP Applications

To analyze your own HIP kernels, compile them with an Omniprobe LLVM plugin
and run with `omniprobe -i`. The plugin creates instrumented kernel clones
alongside the originals — no source changes needed.
See [docs/hip-instrumentation.md](docs/hip-instrumentation.md) for the full
guide, including scoped instrumentation and CMake integration.

## Instrumenting Libraries

Pre-compiled GPU libraries (rocBLAS, hipBLASLt) require special instrumented
builds before Omniprobe can analyze their kernels.
See [docs/rocblas-maximal-instrumentation.md](docs/rocblas-maximal-instrumentation.md)
for a walkthrough.

## Triton Support

Omniprobe can instrument Triton kernels by intercepting the Triton compilation
cache. See [docs/triton-instrumentation.md](docs/triton-instrumentation.md).

## Project Structure

```
omniprobe/
    omniprobe/          CLI script and Python config
    src/                Interceptor, handlers, and instrumentation passes
    inc/                C++ headers
    plugins/            Handler plugin interface
    tests/              Test kernels and test runner scripts
    containers/         Dockerfiles, Apptainer defs, build/run scripts
    external/           Git submodules (dh_comms, kerneldb)
    docs/               Documentation
```

## License

MIT — see [LICENSE](LICENSE) for details.

# Omniprobe

[![Ubuntu Linux (ROCm, LLVM)](https://github.com/AMDResearch/omniprobe/actions/workflows/ubuntu.yml/badge.svg)](https://github.com/AMDResearch/omniprobe/actions/workflows/ubuntu.yml)
[![RedHat Linux (ROCm, LLVM)](https://github.com/AMDResearch/omniprobe/actions/workflows/redhat.yml/badge.svg)](https://github.com/AMDResearch/omniprobe/actions/workflows/redhat.yml)

> [!IMPORTANT]  
> This project is in an alpha state. We are making it available early because of significant interest in having access to it now. There is still some productization and packaging to do. And many more tests need to be added. It works, but if you use it enough, you will undoubtedly find corner cases where things go wrong. The good news is that you _can_ mostly have far more performance visibility inside kernels running on AMD Instinct GPUs than has ever been possible before.

Omniprobe was originally called 'logduration' and was begun simply to provide a quick and easy way to observe all kernel
durations within any ROCm application, without having to run the profiler or being saddled with all of the application
perturbation profiling introduces (e.g. kernels are often serialized). It turned into something more feature-rich, however.
(Because Omniprobe was originally named 'logduration', as you snoop around the code, you will invariably see 
references to 'logduration', including some of its naming conventions for environment variables.) 

One of the longstanding challenges doing software performance optimization on AMD GPUs has been the lack of visibility
into _intra_-kernel performance. Hardware performance counters are only attributable to specific kernel dispatches when
kernels are serialized and counters are gathered on kernel dispatch boundaries (i.e. before a kernel is dispatched and 
after it completes.) This means that developers typically only have _aggregate_ visibility into performance  - 
a kind of average - but pinpointing specific bottlenecks in code can be problematic. Developers have to infer
from aggregate performance what _might_ be the source of a bottleneck. It isn't that this can't be done, it just makes 
the whole business of performance optimization harder and take longer. And it sometimes imposes on developers the need to 
reason from various aspects of specific hardware micro-architectures back to software and compiler implementations.

Omniprobe is a vehicle to facilitate attributing many common bottlenecks inside kernels to specific lines of kernel source code. It accomplishes
this by injecting code at compile-time into targeted kernels. The code that it injects is selectively placed and results in 
instrumented kernels that stream context-laden messages to the host while they are running. logduration processes and analyzes these
messages with one or multiple host-side "message handlers". From the information contained in these messages, it is possible to
isolate many common-case bottlenecks that can inadvertently be written into code.

Not every possible bottleneck can be identified and isolated in this way. Instrumenting code necessarily perturbs the behavior
of a kernel. But there are many common bottlenecks for which this perturbation is not a problem. Some bottleneck detection examples
we have already implemented are:

- Memory Access Inefficiencies
  - Bank Conflicts
  - Non-coalesced memory accesses
  - Non-aligned memory accesses
- Branchiness

We have also implemented analytics to provide fine-grained intra-kernel performance measurement (e.g. at basic block granularity),
detailed instruction counting by instruction type, memory heatmap analysis, and others.

logduration is a platform for implementing new intra-kernel observation and analysis functionality. We are just getting started
with new analytics and have additional useful capabilities both in development and planned.

## omniprobe
`omniprobe` is a command-line python wrapper around the functionality provided by `liblogDuration`. It simplifies the process of setting up
the environment and launching instrumented applications. The various environment variables are documented below, though they
only need to be explicitly set by the user if logduration is needed in a context for which running the python wrapper is not
feasible.

```
Omniprobe is developed by Advanced Micro Devices, Research and Advanced Development
Copyright (c) 2025 Advanced Micro Devices. All rights reserved.

usage: omniprobe [options] -- application

Command-line interface for running intra-kernel analytics on AMD Instinct GPUs

Help:
  -h, --help                  show this help message and exit

General omniprobe arguments:
  -v, --verbose               	Verbose output
  -k , --kernels              	Kernel filters to define which kernels are instrumented. Valid ECMAScript regular expressions are supported. (cf. https://cplusplus.com/reference/regex/ECMAScript/)
  -i, --instrumented, --no-instrumented
                              	Run instrumented kernels (default: False)
  -e, --env-dump, --no-env-dump
                              	Dump all the environment variables for running liblogDuration64.so. (default: False)
  -d , --dispatches           	The dispatches for which to capture instrumentation output. This only applies when running with --instrumented.  Valid options: [all, random, 1]
  -c , --cache-location       	The location of the file system cache for instrumented kernels. For Triton this is typically found at $HOME/.triton/cache
  -t , --log-format           	The format for logging results. Default is 'csv'. Valid options: [csv|json]
  -l , --log-location         	The location where all your data should be logged. By default, it will be to the console.
  -a  [ ...], --analyzers  [ ...]
                              	The analyzer(s) to use for processing data being streamed from instrumented kernels. 
                              	Valid values are ['MessageLogger', 'Heatmap', 'MemoryAnalysis', 'BasicBlockAnalysis'] or a reference to any shared library that implements an omniprobe message handler.
  -- [ ...]                   	Provide command for instrumenting after a double dash.
```

## Environment Variables
- LOGDUR_LOG_LOCATION
  - console
  - file name
  - /dev/null
- LOGDUR_KERNEL_CACHE
  - The kernel cache should be pointed at a directory containing .hsaco files which represented alternative candidates
  to the kernels being dispatched by the application. If running "instrumented kernels" (see the next environment variable description), logDuration
  will look for an identically named kernel with the same parameter list and types, but with a single additional void * parameter (needed for the
  data streaming to the host from instrumented kernels.) If logDuration is not running in instrumented mode (e.g. LOGDUR_INSTRUMENTED = "false"),
  when the kernel cache is enabled it will look for kernels in the cache having identical names and parameters. This can be useful when wanting
  to compare different versions of the same kernel for overall duration.
- LOGDUR_INSTRUMENTED
  - Value can be either "true" or "false". If set to "true", the kernel cache will replace dispatched kernels with an instrumented alternative.
- LOGDUR_DISPATCHES=all | random | 1
  - Default is to capture data on all dispatches. Setting to 'random' will (unsurprisingly) capture data on random dispatches. Setting to '1' will capture a single dispatch for each unique kernel in the application.
- LOGDUR_INSTRUMENTED=true
- LOGDUR_HANDLERS=\<Message Handler for processing messages from instrumented kernels.\> e.g. libLogMessages64.so
- LOGDUR_LOG_FORMAT=json
- TRITON_LOGGER_LEVEL=3
- TRITON_ALWAYS_COMPILE=1
- TRITON_DISABLE_LINE_INFO=0
- TRITON_HIP_LLD_PATH=/opt/rocm-6.3.1/llvm/bin/ld.lld
- LLVM_PASS_PLUGIN_PATH=/work1/amd/klowery/logduration/build/external/instrument-amdgpu-kernels-triton/build/lib/libAMDGCNSubmitBBStart-triton.so
- HSA_TOOLS_LIB
  - Set to path of liblogDuration64.so - this causes the ROCm runtime to find and load this library.
- LOGDUR_HANDLERS=libBasicBlocks64.so
  - Set to the message handler(s) that will process the messages streaming out of instrumented kernels.
- LD_LIBRARY_PATH
  - Set to logduration/omniprobe along with wherever else you need the loader to search.

## Building  

### Quick start (container)

We provide containerized execution environments for users to get started with omniprobe right away. Leverage the [`containers/run.sh`](containers/run.sh) script to jump into a container with the project and all of its dependencies pre-installed. Use the `--docker` or `--apptainer` flags to build the image for your preferred container runtime.

Example:
```console
$ ./containers/run.sh 
Error: Must specify either --docker or --apptainer.
Usage: ./containers/run.sh [--docker] [--apptainer] [--rocm VERSION]
  --docker      Run using Docker container
  --apptainer   Run using Apptainer container
  --rocm        ROCm version (default: 6.3, supported: 6.3 6.4)
```

That's it! If a container matching your detected [`VERSION`](VERSION) of omniprobe doesn't exist already, one will be built automatically.

### Build from source

This project has several [dependencies](#dependencies) that are included as submodules. By default, logduration builds with ROCm instrumentation support.

Override the default ROCm LLVM search path via `ROCM_PATH`. To build with support for Triton instrumentation, we require you set `TRITON_LLVM`.

```shell
git clone https://github.com/AARInternal/logduration.git
cd logduration
git submodule update --init --recursive
mkdir build
cd build
cmake -DTRITON_LLVM=$HOME/.triton/llvm/llvm-a66376b0-ubuntu-x64 ..
make
# Optionally, install the program
make install
```

> [!TIP]
> See [FAQ](#faq) for reccomended Triton installation procedure.

## Dependencies
logDuration is a new kind of performance analysis tool. It combines many of the attributes of profilers, compilers, debuggers, and runtimes into a single tool. Because of that, 
logDuration is now dependent on three other libraries that provide various aspects of the functionality it needs.
### [kerneldb](https://github.com/AMDResearch/kerneldb)
> kernelDB provides support for extracting kernel codes from HSA code objects. This can be an important capability for processing instrumented kernel output.
> The omniprobe memory efficiency analyzer relies on this because sometimes code optimizations are made downstream in the compiler from where instrumentation
> occurred. And proper analysis of, say, memory traces requires understanding how the code may have been optimized (e.g. ganging together individual loads into dwordx4)

### [dh_comms](https://github.com/AMDResearch/dh_comms)
> dh_comms provides buffered I/O functionality for propagating messages from instrumented kernels to host code for consuming and analyzing messages from instrumented code at runtime.
> Because logDuration can run in either instrumented or non-instrumented mode, dh_comms functionality needs to be built into logDuration.
> 
### [instrument-amdgpu-kernels](https://github.com/AMDResearch/instrument-amdgpu-kernels)
> Unlike either dh_comms or kerneldb, instrument-amdgpu-kernel does not get linked into logDuration, but the llvm plugins provided by this library do the instrumentation of GPU kernels
> that logDuration relies on when running in instrumented mode. For now, when you build instrument-amdgpu-kernels for logDuration, you need to use the dh_comms_submit_address branch.

## FAQ

### How do you recommend I install Triton?
To build with Triton instrumentation support, we require you provide the path to Triton's LLVM install (`TRITON_LLVM`). We recommend using a virtual Python environment to avoid clobbering your other packages. See [`docker/triton_install.sh`](docker/triton_install.sh) for help creating this virtual environment automatically. 
### Where can I find more information on using Omniprobe?
We are creating some (very) informal tutorial videos that will walk you through things. An introductory tutorial video can be found here:
<a href="https://www.youtube.com/watch?v=NbRDV2p6fv0" target="_blank"><img src="https://img.youtube.com/vi/NbRDV2p6fv0/maxresdefault.jpg"/></a>
All videos that we create will be posted at this Youtube channel: [Omniprobe Youtube](https://www.youtube.com/@KeithLowery-w9v)



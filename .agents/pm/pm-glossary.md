# Project Glossary

Project-specific terms, abbreviations, and parameters. Updated by `pm-update`.

## GPU Architecture

| Term | Definition |
|------|------------|
| Lane | Single thread within a wavefront (0-63) |
| Wavefront/Wave | Group of 64 threads executing in lockstep (AMD terminology; NVIDIA calls this a warp) |
| Workgroup | Group of wavefronts sharing LDS |
| LDS (Local Data Share) | Fast on-chip shared memory within a workgroup |
| Bank | LDS partition (32 banks of 4 bytes each) |
| Bank Conflict | Multiple lanes accessing different addresses in same bank, causing serialization |
| Cache Line | Unit of memory transfer (typically 64 bytes) |
| Coalesced Access | Memory access pattern where lanes access consecutive addresses, yielding optimal cache usage |
| Uncoalesced Access | Scattered access pattern requiring more cache lines than optimal |

## HSA/ROCm

| Term | Definition |
|------|------------|
| HSA | Heterogeneous System Architecture — standard for CPU-GPU integration |
| HSA Tools Library | (Legacy, deprecated) Shared library loaded via `HSA_TOOLS_LIB`. Omniprobe now uses rocprofiler-sdk |
| AQL | Architected Queuing Language — HSA command queue packet format |
| Dispatch Packet | AQL packet that launches a kernel |
| Kernel Object | Handle identifying a compiled kernel |
| Kernarg | Kernel argument buffer passed to dispatch |

## LLVM/Compilation

| Term | Definition |
|------|------------|
| IR | LLVM Intermediate Representation — platform-independent code format |
| ISA | Instruction Set Architecture — target-specific machine instructions |
| DWARF | Debug information format (file, line, column) |
| Code Object | Compiled GPU binary (ELF format with embedded kernels) |
| Pass Plugin | LLVM plugin that transforms IR |

## Omniprobe Components

| Term | Definition |
|------|------------|
| dh_comms | Device-host communication library |
| kerneldb | Kernel database (ISA + DWARF) |
| Interceptor | HSA API hook layer (`liblogDuration`) |
| Message Handler | Class that processes streamed messages |
| Handler Chain | Ordered list of handlers; first match processes message |
| Descriptor | `dh_comms_descriptor` struct with buffer pointers |

## Message Types

| Term | Definition |
|------|------------|
| Address Message | Contains 64 addresses (one per lane) + DWARF info + access metadata |
| Sub-buffer | Partition of main message buffer for parallelism |
| Atomic Flag | Synchronization between device writers and host reader |

## GPU Memory Hierarchy

| Term | Definition |
|------|------------|
| TCP | Texture Cache per-CU (L1 data cache), 32 KB per CU, write-through write-no-allocate |
| TCA | Texture Cache Arbiter — per-SE arbiter routing CU requests to TCX crossbar |
| TCX | Texture Cache Crossbar — connects all TCAs to all TCC channels within an XCC |
| TCC | Texture Cache per-Channel (L2 cache) — 16 channels per XCC, 256 KB per channel, 4 MB total per XCC |
| MTYPE | Memory Type — PTE-level cache policy (UC=uncacheable, NC=non-coherent, RW=read-write, CC=cached-coherent) |
| MTYPE_UC | Uncacheable — traffic passes through TCC for routing but does NOT allocate cache lines |
| SLC | System-Level Cache hint (gfx90a) — streaming eviction policy at L2, does NOT bypass L2 |

## SQTT (SQ Thread Trace)

| Term | Definition |
|------|------------|
| SQTT | SQ Thread Trace — hardware mechanism for tracing shader execution |
| SQG | SQ Global — block inside SPI that collects SQTT tokens from all CUs in an SE, adds timestamps, writes 256-bit packets to memory |
| s_ttracedata | Scalar instruction inserting M0 content as user data token into SQTT stream; executes as s_nop when tracing disabled |
| ATT | Advanced Thread Tracing — public name for SQTT in rocprofv3/rocprofiler-sdk |
| TCC_PERF_EN | SQTT_MODE bit controlling whether SQTT traffic counts in TCC performance counters (counter visibility only, not data path) |
| aqlprofile | ROCm library generating PM4 command packets for SQTT/perf counter programming |

## Analysis

| Term | Definition |
|------|------------|
| Conflict Set | Group of lanes that may cause bank conflicts with each other |
| IR Access Size | Memory access size at LLVM IR level |
| ISA Access Size | Actual access size after backend optimization (may differ from IR) |
| dwordx4 | 16-byte vector load/store instruction (4 dwords) |

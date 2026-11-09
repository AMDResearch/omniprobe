"""Result dataclasses for Omniprobe analysis output."""

from dataclasses import dataclass, field


# Every top-level result carries ``uninstrumented_kernels``: kernel name ->
# number of dispatches that ran without an instrumented clone (from omniprobe's
# end-of-run summary). Those kernels are missing from the analysis; a non-empty
# dict means the result is partial.


@dataclass
class MemoryAccess:
    """A single memory access observation at a source location.

    ``cache_lines_needed`` / ``cache_lines_used`` are summed over the
    ``execution_count`` wave-level executions (global accesses); their
    difference is ``excess_cache_lines``. ``ir_bytes`` is the accessed type's
    size in the IR, ``isa_bytes`` the size the ISA instruction moves.
    ``serialized_lanes`` (LDS float atomics on gfx950): active lanes served one
    at a time; the hardware does not count these as bank conflicts.
    """
    source_file: str
    line: int
    column: int
    excess_cache_lines: int
    bank_conflicts: int
    memory_space: str = ""
    access_type: str = ""
    execution_count: int = 0
    cache_lines_needed: int = 0
    cache_lines_used: int = 0
    isa_instruction: str = ""
    ir_bytes: int = 0
    isa_bytes: int = 0
    serialized_lanes: int = 0


@dataclass
class KernelMemoryResult:
    """Memory analysis results for a single kernel dispatch.

    ``unanalyzed_flat_accesses`` counts wave-level accesses through flat
    pointers whose lanes pointed into different address spaces; they are not
    analyzed. Other flat accesses (-O0 builds, pointers loaded from memory)
    are classified at run time and analyzed like any other.
    ``unattributed_accesses`` counts wave-level global accesses dropped because
    no ISA instruction was found for their source line; all of them when the
    binary has no debug info (build with -g).
    ``merged_lds_accesses`` counts wave-level LDS accesses that the compiler
    merged into a DS instruction carrying another access's source location
    (gfx950); that access counts the instruction's bank conflicts.
    """
    kernel_name: str
    dispatch_id: int
    accesses: list[MemoryAccess] = field(default_factory=list)
    unanalyzed_flat_accesses: int = 0
    unattributed_accesses: int = 0
    merged_lds_accesses: int = 0
    # Per-kernel dispatch number (the n-th dispatch of this kernel, from 1), as
    # selected with dispatches=; dispatch_id counts all kernels together.
    kernel_dispatch: int = 0


@dataclass
class MemoryAnalysisResult:
    """Top-level result from memory analysis."""
    kernels: list[KernelMemoryResult] = field(default_factory=list)
    uninstrumented_kernels: dict[str, int] = field(default_factory=dict)


@dataclass
class BasicBlock:
    """Execution counts and source location for one basic block.

    bb_id is the BBStart plugin's number for the block (its position in the
    instrumented kernel), stable for a given binary. wave_visits counts how
    often a wave entered the block; active_lanes sums the active lanes over
    those entries, so active_lanes / wave_visits is the mean lane occupancy.
    There is no timing: per-block durations are not measured (see docs/usage.md).
    """
    bb_id: int
    source_file: str
    line: int
    column: int = 0
    wave_visits: int = 0
    active_lanes: int = 0


@dataclass
class KernelBBResult:
    """Basic block analysis results for a single kernel dispatch."""
    kernel_name: str
    dispatch_id: int
    basic_blocks: list[BasicBlock] = field(default_factory=list)
    # Per-kernel dispatch number (the n-th dispatch of this kernel, from 1), as
    # selected with dispatches=; dispatch_id counts all kernels together.
    kernel_dispatch: int = 0


@dataclass
class BasicBlockResult:
    """Top-level result from basic block analysis."""
    kernels: list[KernelBBResult] = field(default_factory=list)
    uninstrumented_kernels: dict[str, int] = field(default_factory=dict)


@dataclass
class HeatmapPage:
    """Accesses to one page (``end_address`` is inclusive)."""
    start_address: int
    end_address: int
    accesses: int


@dataclass
class KernelHeatmap:
    """Per-page access counts for a single kernel dispatch."""
    kernel_name: str
    dispatch_id: int
    page_size: int
    pages: list[HeatmapPage] = field(default_factory=list)
    # Per-kernel dispatch number (the n-th dispatch of this kernel, from 1), as
    # selected with dispatches=; dispatch_id counts all kernels together.
    kernel_dispatch: int = 0


@dataclass
class HeatmapResult:
    """Top-level result from the Heatmap analyzer."""
    kernels: list[KernelHeatmap] = field(default_factory=list)
    uninstrumented_kernels: dict[str, int] = field(default_factory=dict)


@dataclass
class AddressRecord:
    """One instrumented memory instruction executed by one wave.

    ``addresses`` has one entry per active lane, in increasing lane order
    (``len(addresses) == active_lane_count``). ``source_file``/``line``/
    ``column`` are the instruction's own debug location, which for code
    inlined from a header (e.g. HIP's ``blockDim``) is the header.
    ``access_size`` is the accessed type's size in bytes.
    """
    kernel_name: str
    dispatch_id: int
    timestamp: int
    exec_mask: int
    active_lane_count: int
    block_idx: tuple[int, int, int]
    wave_num: int
    xcc_id: int
    se_id: int
    cu_id: int
    op_type: str
    memory_space: str
    access_size: int
    source_file: str
    line: int
    column: int
    addresses: list[int] = field(default_factory=list)
    # Per-kernel dispatch number (the n-th dispatch of this kernel, from 1), as
    # selected with dispatches=; dispatch_id counts all kernels together.
    kernel_dispatch: int = 0


@dataclass
class AddressTrace:
    """Records from the AddressLogger analyzer.

    ``truncated`` is True when ``max_records`` stopped the parse before the
    end of the trace.
    """
    records: list[AddressRecord] = field(default_factory=list)
    truncated: bool = False
    uninstrumented_kernels: dict[str, int] = field(default_factory=dict)


@dataclass
class BBRecord:
    """One wave entering one basic block (BasicBlockLogger, BBStart binary).

    ``basic_block_id`` is the same id BasicBlockAnalysis reports.
    """
    kernel_name: str
    dispatch_id: int
    timestamp: int
    exec_mask: int
    active_lane_count: int
    block_idx: tuple[int, int, int]
    wave_num: int
    xcc_id: int
    se_id: int
    cu_id: int
    basic_block_id: int
    source_file: str
    line: int
    column: int
    # Per-kernel dispatch number (the n-th dispatch of this kernel, from 1), as
    # selected with dispatches=; dispatch_id counts all kernels together.
    kernel_dispatch: int = 0


@dataclass
class BasicBlockTrace:
    """Records from the BasicBlockLogger analyzer."""
    records: list[BBRecord] = field(default_factory=list)
    truncated: bool = False
    uninstrumented_kernels: dict[str, int] = field(default_factory=dict)

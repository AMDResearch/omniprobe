"""Result dataclasses for Omniprobe analysis output."""

from dataclasses import dataclass, field


@dataclass
class MemoryAccess:
    """A single memory access observation at a source location."""
    source_file: str
    line: int
    column: int
    excess_cache_lines: int
    bank_conflicts: int
    memory_space: str = ""
    access_type: str = ""
    execution_count: int = 0


@dataclass
class KernelMemoryResult:
    """Memory analysis results for a single kernel dispatch."""
    kernel_name: str
    dispatch_id: int
    accesses: list[MemoryAccess] = field(default_factory=list)


@dataclass
class MemoryAnalysisResult:
    """Top-level result from memory analysis."""
    kernels: list[KernelMemoryResult] = field(default_factory=list)


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


@dataclass
class BasicBlockResult:
    """Top-level result from basic block analysis."""
    kernels: list[KernelBBResult] = field(default_factory=list)

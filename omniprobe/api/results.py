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
    """Timing and location data for a single basic block."""
    bb_id: int
    source_file: str
    line: int
    min_cycles: float
    max_cycles: float
    p25: float = 0.0
    p50: float = 0.0
    p75: float = 0.0
    p95: float = 0.0
    p99: float = 0.0
    wave_count: int = 0


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

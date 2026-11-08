"""Python API for driving Omniprobe and parsing structured JSON results."""

import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Callable, Optional, TypeVar

from .results import (
    AddressRecord,
    AddressTrace,
    BasicBlock,
    BasicBlockResult,
    BasicBlockTrace,
    BBRecord,
    HeatmapPage,
    HeatmapResult,
    KernelBBResult,
    KernelHeatmap,
    KernelMemoryResult,
    MemoryAccess,
    MemoryAnalysisResult,
)

T = TypeVar("T")

# omniprobe's end-of-run summary of kernels that ran without an instrumented
# clone (src/interceptor.cc, ~hsaInterceptor).
_UNINSTRUMENTED_HEADER = "kernel(s) ran uninstrumented because no instrumented clone was found"
_UNINSTRUMENTED_ENTRY = re.compile(r"^  (.*) \((\d+) dispatch(?:es)?\)$")


class Omniprobe:
    """Programmatic interface to the Omniprobe GPU analysis toolkit.

    Drives the ``omniprobe`` CLI with ``-t json`` and parses the resulting
    JSON into structured Python objects.

    Parameters
    ----------
    omniprobe_path : str or None
        Explicit path to the ``omniprobe`` executable.  When *None*
        (the default), the executable is located via ``PATH``.

    Raises
    ------
    FileNotFoundError
        If the ``omniprobe`` executable cannot be found.
    """

    def __init__(self, omniprobe_path: Optional[str] = None) -> None:
        if omniprobe_path is not None:
            p = Path(omniprobe_path)
            if not p.exists():
                raise FileNotFoundError(
                    f"omniprobe executable not found at {omniprobe_path}"
                )
            self._exe = str(p)
        else:
            exe = shutil.which("omniprobe") or self._sibling_executable()
            if exe is None:
                raise FileNotFoundError(
                    "omniprobe executable not found on PATH or next to "
                    "this package"
                )
            self._exe = exe

    @staticmethod
    def _sibling_executable() -> Optional[str]:
        """The omniprobe launcher shipped with this package, if any.

        Install tree: ``<prefix>/omniprobe/{api,bin/omniprobe}``; source tree:
        ``omniprobe/{api,omniprobe}``. Lets callers with a minimal ``PATH``
        (e.g. MCP servers) use the API without configuring anything.
        """
        root = Path(__file__).resolve().parent.parent
        for candidate in (root / "bin" / "omniprobe", root / "omniprobe"):
            if candidate.is_file():
                return str(candidate)
        return None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def analyze_memory(
        self,
        command: str,
        kernel_filter: Optional[str] = None,
        dispatches: str = "all",
    ) -> MemoryAnalysisResult:
        """Run memory analysis on *command* and return structured results.

        Parameters
        ----------
        command : str
            The application command line to instrument (will be split by
            the shell).
        kernel_filter : str or None
            Optional ECMAScript regex to limit which kernels are analysed.
        dispatches : str
            Which dispatches to capture (``"all"``, ``"random"``, or ``"1"``).
            ``"random"`` captures each dispatch with probability 1/100, so a
            kernel with few dispatches is often not captured at all.

        Returns
        -------
        MemoryAnalysisResult
        """
        raw, log = self._run(
            command,
            analyzer="MemoryAnalysis",
            kernel_filter=kernel_filter,
            dispatches=dispatches,
        )
        result = self._parse_memory(raw)
        result.uninstrumented_kernels = self._parse_uninstrumented(log)
        return result

    def analyze_basic_blocks(
        self,
        command: str,
        kernel_filter: Optional[str] = None,
        dispatches: str = "all",
    ) -> BasicBlockResult:
        """Run basic-block analysis on *command* and return structured results.

        Parameters
        ----------
        command : str
            The application command line to instrument.
        kernel_filter : str or None
            Optional ECMAScript regex to limit which kernels are analysed.
        dispatches : str
            Which dispatches to capture.

        Returns
        -------
        BasicBlockResult
        """
        raw, log = self._run(
            command,
            analyzer="BasicBlockAnalysis",
            kernel_filter=kernel_filter,
            dispatches=dispatches,
        )
        result = self._parse_basic_blocks(raw)
        result.uninstrumented_kernels = self._parse_uninstrumented(log)
        return result

    def analyze_heatmap(
        self,
        command: str,
        kernel_filter: Optional[str] = None,
        dispatches: str = "all",
    ) -> HeatmapResult:
        """Run the Heatmap analyzer: accesses per page, per dispatch.

        Needs a binary instrumented with the AddressMessages plugin.
        """
        def parse(path: Path) -> HeatmapResult:
            result = HeatmapResult()
            for entry in self._json_lines(path):
                result.kernels.append(
                    KernelHeatmap(
                        kernel_name=entry.get("kernel", "<unknown>"),
                        dispatch_id=entry.get("dispatch_id", 0),
                        page_size=entry.get("page_size", 0),
                        pages=[
                            HeatmapPage(
                                start_address=p.get("start_address", 0),
                                end_address=p.get("end_address", 0),
                                accesses=p.get("accesses", 0),
                            )
                            for p in entry.get("pages", [])
                        ],
                    )
                )
            return result

        result, log = self._run_and_parse(
            command, "Heatmap", kernel_filter, dispatches, parse)
        result.uninstrumented_kernels = self._parse_uninstrumented(log)
        return result

    def log_addresses(
        self,
        command: str,
        kernel_filter: Optional[str] = None,
        dispatches: str = "all",
        max_records: Optional[int] = None,
    ) -> AddressTrace:
        """Run the AddressLogger analyzer and return its per-wave records.

        One record per instrumented memory instruction executed by a wave,
        with one address per active lane. The trace file is parsed as a
        stream, so with *max_records* set at most that many records are held
        in memory (``truncated`` tells whether more followed). Needs a binary
        instrumented with the AddressMessages plugin.
        """
        def parse(path: Path) -> AddressTrace:
            trace = AddressTrace()
            for d in self._json_lines(path):
                if d.get("user_type") != 0:
                    continue
                if max_records is not None and len(trace.records) >= max_records:
                    trace.truncated = True
                    break
                trace.records.append(
                    AddressRecord(
                        kernel_name=d.get("kernel_name", "<unknown>"),
                        dispatch_id=d.get("dispatch_id", 0),
                        timestamp=d.get("timestamp", 0),
                        exec_mask=d.get("exec", 0),
                        active_lane_count=d.get("active_lane_count", 0),
                        block_idx=(d.get("block_idx_x", 0), d.get("block_idx_y", 0), d.get("block_idx_z", 0)),
                        wave_num=d.get("wave_num", 0),
                        xcc_id=d.get("xcc_id", 0),
                        se_id=d.get("se_id", 0),
                        cu_id=d.get("cu_id", 0),
                        op_type=d.get("op_type", ""),
                        memory_space=d.get("memory_space", ""),
                        access_size=d.get("access_size", 0),
                        source_file=d.get("source_file", ""),
                        line=d.get("dwarf_line", 0),
                        column=d.get("dwarf_column", 0),
                        addresses=d.get("addresses", []),
                    )
                )
            return trace

        trace, log = self._run_and_parse(
            command, "AddressLogger", kernel_filter, dispatches, parse)
        trace.uninstrumented_kernels = self._parse_uninstrumented(log)
        return trace

    def log_basic_blocks(
        self,
        command: str,
        kernel_filter: Optional[str] = None,
        dispatches: str = "all",
        max_records: Optional[int] = None,
    ) -> BasicBlockTrace:
        """Run the BasicBlockLogger analyzer: one record per wave per block entered.

        Needs a binary instrumented with the BBStart plugin. Streamed like
        :meth:`log_addresses`.
        """
        def parse(path: Path) -> BasicBlockTrace:
            trace = BasicBlockTrace()
            for d in self._json_lines(path):
                if d.get("user_type") != 2:
                    continue
                if max_records is not None and len(trace.records) >= max_records:
                    trace.truncated = True
                    break
                trace.records.append(
                    BBRecord(
                        kernel_name=d.get("kernel_name", "<unknown>"),
                        dispatch_id=d.get("dispatch_id", 0),
                        timestamp=d.get("timestamp", 0),
                        exec_mask=d.get("exec", 0),
                        active_lane_count=d.get("active_lane_count", 0),
                        block_idx=(d.get("block_idx_x", 0), d.get("block_idx_y", 0), d.get("block_idx_z", 0)),
                        wave_num=d.get("wave_num", 0),
                        xcc_id=d.get("xcc_id", 0),
                        se_id=d.get("se_id", 0),
                        cu_id=d.get("cu_id", 0),
                        basic_block_id=d.get("basic_block_id", d.get("user_data", 0)),
                        source_file=d.get("source_file", ""),
                        line=d.get("dwarf_line", 0),
                        column=d.get("dwarf_column", 0),
                    )
                )
            return trace

        trace, log = self._run_and_parse(
            command, "BasicBlockLogger", kernel_filter, dispatches, parse)
        trace.uninstrumented_kernels = self._parse_uninstrumented(log)
        return trace

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _run_and_parse(
        self,
        command: str,
        analyzer: str,
        kernel_filter: Optional[str],
        dispatches: str,
        parse: Callable[[Path], T],
    ) -> tuple[T, str]:
        """Run *analyzer* with ``-t json -o <tmp>``, then ``parse(<tmp>)``.

        Returns the parsed result and omniprobe's combined stdout/stderr.
        Raises RuntimeError if omniprobe exits non-zero.
        """
        with tempfile.NamedTemporaryFile(
            suffix=".json", prefix="omniprobe_", delete=False
        ) as tmp:
            tmp_path = Path(tmp.name)

        try:
            args = [
                self._exe,
                "-a", analyzer,
                "-i",
                "-t", "json",
                "-o", str(tmp_path),
                "-d", dispatches,
            ]
            if kernel_filter is not None:
                args.extend(["-k", kernel_filter])
            args.append("--")
            args.extend(command.split())

            result = subprocess.run(
                args,
                capture_output=True,
                text=True,
            )

            if result.returncode != 0:
                raise RuntimeError(
                    f"omniprobe exited with code {result.returncode}: "
                    f"{result.stderr or result.stdout}"
                )

            return parse(tmp_path), (result.stdout or "") + (result.stderr or "")
        finally:
            tmp_path.unlink(missing_ok=True)

    def _run(
        self,
        command: str,
        analyzer: str,
        kernel_filter: Optional[str],
        dispatches: str,
    ) -> tuple[str, str]:
        """Invoke the omniprobe CLI; return the raw JSON text and its log."""
        def read(path: Path) -> str:
            if path.exists() and path.stat().st_size > 0:
                return path.read_text()
            return "[]"

        return self._run_and_parse(command, analyzer, kernel_filter, dispatches, read)

    @staticmethod
    def _json_lines(path: Path):
        """Yield the objects of a one-object-per-line JSON file, lazily."""
        if not path.exists():
            return
        with path.open() as f:
            for n, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError as exc:
                    raise ValueError(
                        f"Malformed JSON from omniprobe on line {n}: {exc}"
                    ) from exc

    @staticmethod
    def _parse_uninstrumented(log: str) -> dict[str, int]:
        """Kernels omniprobe reported as having run without an instrumented clone."""
        result: dict[str, int] = {}
        in_summary = False
        for line in log.splitlines():
            if _UNINSTRUMENTED_HEADER in line:
                in_summary = True
                continue
            if in_summary:
                m = _UNINSTRUMENTED_ENTRY.match(line)
                if not m:
                    in_summary = False
                    continue
                result[m.group(1)] = int(m.group(2))
        return result

    @staticmethod
    def _parse_memory(raw: str) -> MemoryAnalysisResult:
        """Parse JSON text into a MemoryAnalysisResult."""
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ValueError(f"Malformed JSON from omniprobe: {exc}") from exc

        # Normalize: the handler emits a single object per dispatch or an
        # array of objects when there are multiple dispatches.
        if isinstance(data, dict):
            data = [data]

        result = MemoryAnalysisResult()
        for entry in data:
            kernel_name = entry.get("kernel", "<unknown>")
            dispatch_id = entry.get("dispatch_id", 0)
            accesses_raw = entry.get("accesses", [])
            accesses = []
            for a in accesses_raw:
                accesses.append(
                    MemoryAccess(
                        source_file=a.get("source_file", ""),
                        line=a.get("line", 0),
                        column=a.get("column", 0),
                        excess_cache_lines=a.get("excess_cache_lines", 0),
                        bank_conflicts=a.get("bank_conflicts", 0),
                        memory_space=a.get("memory_space", ""),
                        access_type=a.get("access_type", ""),
                        execution_count=a.get("execution_count", 0),
                        cache_lines_needed=a.get("cache_lines_needed", 0),
                        cache_lines_used=a.get("cache_lines_used", 0),
                        isa_instruction=a.get("isa_instruction", ""),
                        ir_bytes=a.get("ir_bytes", 0),
                        isa_bytes=a.get("isa_bytes", 0),
                    )
                )
            result.kernels.append(
                KernelMemoryResult(
                    kernel_name=kernel_name,
                    dispatch_id=dispatch_id,
                    accesses=accesses,
                    unanalyzed_flat_accesses=entry.get("unanalyzed_flat_accesses", 0),
                    unattributed_accesses=entry.get("unattributed_accesses", 0),
                )
            )
        return result

    @staticmethod
    def _parse_basic_blocks(raw: str) -> BasicBlockResult:
        """Parse JSON text into a BasicBlockResult."""
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ValueError(f"Malformed JSON from omniprobe: {exc}") from exc

        if isinstance(data, dict):
            data = [data]

        result = BasicBlockResult()
        for entry in data:
            kernel_name = entry.get("kernel", "<unknown>")
            dispatch_id = entry.get("dispatch_id", 0)
            blocks_raw = entry.get("basic_blocks", [])
            blocks = []
            for b in blocks_raw:
                blocks.append(
                    BasicBlock(
                        bb_id=b.get("basic_block_id", 0),
                        source_file=b.get("source_file", ""),
                        line=b.get("line", 0),
                        column=b.get("column", 0),
                        wave_visits=b.get("wave_visits", 0),
                        active_lanes=b.get("active_lanes", 0),
                    )
                )
            result.kernels.append(
                KernelBBResult(
                    kernel_name=kernel_name,
                    dispatch_id=dispatch_id,
                    basic_blocks=blocks,
                )
            )
        return result

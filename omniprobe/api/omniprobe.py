"""Python API for driving Omniprobe and parsing structured JSON results."""

import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Optional

from .results import (
    BasicBlock,
    BasicBlockResult,
    KernelBBResult,
    KernelMemoryResult,
    MemoryAccess,
    MemoryAnalysisResult,
)


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
            exe = shutil.which("omniprobe")
            if exe is None:
                raise FileNotFoundError(
                    "omniprobe executable not found on PATH"
                )
            self._exe = exe

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

        Returns
        -------
        MemoryAnalysisResult
        """
        raw = self._run(
            command,
            analyzer="MemoryAnalysis",
            kernel_filter=kernel_filter,
            dispatches=dispatches,
        )
        return self._parse_memory(raw)

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
        raw = self._run(
            command,
            analyzer="BasicBlockAnalysis",
            kernel_filter=kernel_filter,
            dispatches=dispatches,
        )
        return self._parse_basic_blocks(raw)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _run(
        self,
        command: str,
        analyzer: str,
        kernel_filter: Optional[str],
        dispatches: str,
    ) -> str:
        """Invoke the omniprobe CLI and return the raw JSON string."""
        with tempfile.NamedTemporaryFile(
            suffix=".json", prefix="omniprobe_", delete=False
        ) as tmp:
            tmp_path = tmp.name

        try:
            args = [
                self._exe,
                "-a", analyzer,
                "-i",
                "-t", "json",
                "-o", tmp_path,
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

            output_path = Path(tmp_path)
            if output_path.exists() and output_path.stat().st_size > 0:
                return output_path.read_text()

            return "[]"
        finally:
            Path(tmp_path).unlink(missing_ok=True)

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
                    )
                )
            result.kernels.append(
                KernelMemoryResult(
                    kernel_name=kernel_name,
                    dispatch_id=dispatch_id,
                    accesses=accesses,
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
                        min_cycles=b.get("min_cycles", 0.0),
                        max_cycles=b.get("max_cycles", 0.0),
                        p25=b.get("p25", 0.0),
                        p50=b.get("p50", 0.0),
                        p75=b.get("p75", 0.0),
                        p95=b.get("p95", 0.0),
                        p99=b.get("p99", 0.0),
                        wave_count=b.get("wave_count", 0),
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

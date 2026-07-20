"""Unit tests for the Omniprobe Python API.

These tests verify JSON parsing, result dataclass construction, and error
handling without requiring a GPU or the omniprobe binary.
"""

import json
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# Add omniprobe directory to path so we can import the API
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "omniprobe"))

from api import (
    BasicBlock,
    BasicBlockResult,
    KernelBBResult,
    KernelMemoryResult,
    MemoryAccess,
    MemoryAnalysisResult,
    Omniprobe,
)


# ── Sample JSON payloads matching the C++ handler output schemas ──────


MEMORY_ANALYSIS_JSON = json.dumps([
    {
        "kernel": "add_kernel",
        "dispatch_id": 1,
        "accesses": [
            {
                "source_file": "/tmp/test.hip",
                "line": 42,
                "column": 5,
                "memory_space": "global",
                "access_type": "read",
                "execution_count": 100,
                "ir_bytes": 4,
                "isa_bytes": 16,
                "isa_instruction": "global_load_dwordx4",
                "cache_lines_needed": 2,
                "cache_lines_used": 5,
                "excess_cache_lines": 3,
                "bank_conflicts": 0,
            },
            {
                "source_file": "/tmp/test.hip",
                "line": 50,
                "column": 10,
                "memory_space": "lds",
                "access_type": "write",
                "execution_count": 200,
                "ir_bytes": 4,
                "excess_cache_lines": 0,
                "bank_conflicts": 12,
            },
        ],
        "metadata": {
            "version": "0.1.0",
            "timestamp": "2026-07-20 18:00:00",
            "gpu_info": {"architecture": "gfx90a", "cache_line_size": 128},
        },
    }
])

BASIC_BLOCK_JSON = json.dumps({
    "kernel": "matmul_kernel",
    "dispatch_id": 2,
    "basic_blocks": [
        {
            "basic_block_id": 0,
            "source_file": "/tmp/matmul.hip",
            "line": 10,
            "end_line": 25,
            "min_cycles": 100.0,
            "max_cycles": 500.0,
            "p25": 150.0,
            "p50": 200.0,
            "p75": 300.0,
            "p95": 450.0,
            "p99": 490.0,
            "wave_count": 64,
        },
        {
            "basic_block_id": 1,
            "source_file": "/tmp/matmul.hip",
            "line": 26,
            "end_line": 40,
            "min_cycles": 50.0,
            "max_cycles": 120.0,
            "p25": 60.0,
            "p50": 70.0,
            "p75": 90.0,
            "p95": 110.0,
            "p99": 118.0,
            "wave_count": 64,
        },
    ],
})

EMPTY_JSON = "[]"


class TestMemoryAnalysisParsing(unittest.TestCase):
    """Test _parse_memory with various JSON inputs."""

    def test_parse_single_dispatch(self):
        result = Omniprobe._parse_memory(MEMORY_ANALYSIS_JSON)
        self.assertIsInstance(result, MemoryAnalysisResult)
        self.assertEqual(len(result.kernels), 1)

        k = result.kernels[0]
        self.assertEqual(k.kernel_name, "add_kernel")
        self.assertEqual(k.dispatch_id, 1)
        self.assertEqual(len(k.accesses), 2)

        a0 = k.accesses[0]
        self.assertEqual(a0.source_file, "/tmp/test.hip")
        self.assertEqual(a0.line, 42)
        self.assertEqual(a0.column, 5)
        self.assertEqual(a0.excess_cache_lines, 3)
        self.assertEqual(a0.bank_conflicts, 0)
        self.assertEqual(a0.access_type, "read")
        self.assertEqual(a0.execution_count, 100)

        a1 = k.accesses[1]
        self.assertEqual(a1.excess_cache_lines, 0)
        self.assertEqual(a1.bank_conflicts, 12)

    def test_parse_single_object(self):
        """Single-dispatch JSON (not wrapped in array)."""
        single = json.dumps({
            "kernel": "test",
            "dispatch_id": 1,
            "accesses": [],
        })
        result = Omniprobe._parse_memory(single)
        self.assertEqual(len(result.kernels), 1)
        self.assertEqual(result.kernels[0].kernel_name, "test")

    def test_parse_empty(self):
        result = Omniprobe._parse_memory(EMPTY_JSON)
        self.assertEqual(len(result.kernels), 0)

    def test_parse_malformed_json(self):
        with self.assertRaises(ValueError):
            Omniprobe._parse_memory("not json {{{")


class TestBasicBlockParsing(unittest.TestCase):
    """Test _parse_basic_blocks with various JSON inputs."""

    def test_parse_single_dispatch(self):
        result = Omniprobe._parse_basic_blocks(BASIC_BLOCK_JSON)
        self.assertIsInstance(result, BasicBlockResult)
        self.assertEqual(len(result.kernels), 1)

        k = result.kernels[0]
        self.assertEqual(k.kernel_name, "matmul_kernel")
        self.assertEqual(k.dispatch_id, 2)
        self.assertEqual(len(k.basic_blocks), 2)

        bb0 = k.basic_blocks[0]
        self.assertEqual(bb0.bb_id, 0)
        self.assertEqual(bb0.source_file, "/tmp/matmul.hip")
        self.assertEqual(bb0.line, 10)
        self.assertAlmostEqual(bb0.min_cycles, 100.0)
        self.assertAlmostEqual(bb0.max_cycles, 500.0)
        self.assertAlmostEqual(bb0.p50, 200.0)
        self.assertAlmostEqual(bb0.p95, 450.0)
        self.assertAlmostEqual(bb0.p99, 490.0)
        self.assertEqual(bb0.wave_count, 64)

    def test_parse_empty(self):
        result = Omniprobe._parse_basic_blocks(EMPTY_JSON)
        self.assertEqual(len(result.kernels), 0)


class TestOmniprobeInit(unittest.TestCase):
    """Test Omniprobe constructor error handling."""

    def test_missing_explicit_path(self):
        with self.assertRaises(FileNotFoundError):
            Omniprobe(omniprobe_path="/nonexistent/omniprobe")

    @patch("shutil.which", return_value=None)
    def test_not_on_path(self, mock_which):
        with self.assertRaises(FileNotFoundError):
            Omniprobe()

    @patch("shutil.which", return_value="/usr/bin/omniprobe")
    def test_found_on_path(self, mock_which):
        op = Omniprobe()
        self.assertEqual(op._exe, "/usr/bin/omniprobe")


class TestOmniprobeRunErrors(unittest.TestCase):
    """Test error handling in _run (AC-6)."""

    @patch("shutil.which", return_value="/usr/bin/omniprobe")
    def setUp(self, mock_which):
        self.op = Omniprobe()

    @patch("subprocess.run")
    def test_nonzero_exit(self, mock_run):
        mock_run.return_value = MagicMock(
            returncode=1,
            stderr="segfault in kernel",
            stdout="",
        )
        with self.assertRaises(RuntimeError) as ctx:
            self.op._run("./app", "MemAnalysis", None, "all")
        self.assertIn("segfault", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()

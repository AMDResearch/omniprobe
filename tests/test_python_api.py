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
            "column": 15,
            "wave_visits": 16,
            "active_lanes": 1024,
        },
        {
            "basic_block_id": 1,
            "source_file": "/tmp/matmul.hip",
            "line": 26,
            "column": 7,
            "wave_visits": 80,
            "active_lanes": 1280,
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
        self.assertEqual(bb0.column, 15)
        self.assertEqual(bb0.wave_visits, 16)
        self.assertEqual(bb0.active_lanes, 1024)
        self.assertEqual(k.basic_blocks[1].wave_visits, 80)

    def test_parse_empty(self):
        result = Omniprobe._parse_basic_blocks(EMPTY_JSON)
        self.assertEqual(len(result.kernels), 0)


class TestOmniprobeInit(unittest.TestCase):
    """Test Omniprobe constructor error handling."""

    def test_missing_explicit_path(self):
        with self.assertRaises(FileNotFoundError):
            Omniprobe(omniprobe_path="/nonexistent/omniprobe")

    @patch.object(Omniprobe, "_sibling_executable", return_value=None)
    @patch("shutil.which", return_value=None)
    def test_not_on_path(self, mock_which, mock_sibling):
        with self.assertRaises(FileNotFoundError):
            Omniprobe()

    @patch("shutil.which", return_value=None)
    def test_falls_back_to_launcher_next_to_package(self, mock_which):
        # In the source tree the launcher is omniprobe/omniprobe beside api/.
        op = Omniprobe()
        self.assertEqual(Path(op._exe).name, "omniprobe")
        self.assertTrue(Path(op._exe).is_file())

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


def _fake_cli(payload: str, log: str = ""):
    """subprocess.run stand-in: writes *payload* to the -o file, exits 0."""
    def run(args, **kwargs):
        Path(args[args.index("-o") + 1]).write_text(payload)
        return MagicMock(returncode=0, stdout="", stderr=log)
    return run


SUMMARY_LOG = (
    "omniprobe: WARNING: 2 kernel(s) ran uninstrumented because no instrumented clone was found; "
    "they are missing from the analysis:\n"
    "  plain_kernel(int*) [clone .kd] (2 dispatches)\n"
    "  other(float*) [clone .kd] (1 dispatch)\n"
    "hsaInterceptor: Application elapsed usecs: 1us\n"
)

ADDRESS_LINES = "\n".join(json.dumps({
    "kernel_name": "k(int*) [clone .kd]", "dispatch_id": 1, "exec": 0xF, "timestamp": 100 + i,
    "dwarf_line": 15, "dwarf_column": 9, "block_idx_x": i, "block_idx_y": 0, "block_idx_z": 0,
    "wave_num": 0, "xcc_id": 0, "se_id": 1, "cu_id": 2, "active_lane_count": 4, "user_type": 0,
    "source_file": "/src/k.hip", "memory_space": "global", "access_size": 4, "op_type": "write",
    "addresses": [16, 20, 24, 28]}) for i in range(5)) + "\n"

BB_LINES = "\n".join(json.dumps({
    "kernel_name": "k(int*) [clone .kd]", "dispatch_id": 2, "exec": 0xFF, "timestamp": 7,
    "dwarf_line": 12, "dwarf_column": 3, "block_idx_x": 0, "block_idx_y": 1, "block_idx_z": 0,
    "wave_num": 1, "xcc_id": 0, "se_id": 0, "cu_id": 0, "active_lane_count": 8, "user_type": 2,
    "source_file": "/src/k.hip", "user_data": b, "basic_block_id": b}) for b in (0, 1, 1)) + "\n"

HEATMAP_LINES = json.dumps({
    "kernel": "k(int*) [clone .kd]", "dispatch_id": 1, "page_size": 1048576,
    "pages": [{"start_address": 0, "end_address": 1048575, "accesses": 256}]}) + "\n"


class TestNewAnalyzers(unittest.TestCase):
    """analyze_heatmap, log_addresses, log_basic_blocks, uninstrumented_kernels."""

    @patch("shutil.which", return_value="/usr/bin/omniprobe")
    def setUp(self, mock_which):
        self.op = Omniprobe()

    def test_heatmap(self):
        with patch("subprocess.run", side_effect=_fake_cli(HEATMAP_LINES)):
            r = self.op.analyze_heatmap("./app")
        k = r.kernels[0]
        self.assertEqual((k.dispatch_id, k.page_size, len(k.pages)), (1, 1048576, 1))
        self.assertEqual((k.pages[0].start_address, k.pages[0].end_address, k.pages[0].accesses),
                         (0, 1048575, 256))

    def test_log_addresses(self):
        with patch("subprocess.run", side_effect=_fake_cli(ADDRESS_LINES)):
            t = self.op.log_addresses("./app")
        self.assertFalse(t.truncated)
        self.assertEqual(len(t.records), 5)
        r = t.records[2]
        self.assertEqual(r.block_idx, (2, 0, 0))
        self.assertEqual((r.memory_space, r.access_size, r.op_type, r.line), ("global", 4, "write", 15))
        self.assertEqual(r.addresses, [16, 20, 24, 28])
        self.assertEqual(len(r.addresses), r.active_lane_count)

    def test_log_addresses_max_records(self):
        with patch("subprocess.run", side_effect=_fake_cli(ADDRESS_LINES)):
            t = self.op.log_addresses("./app", max_records=3)
        self.assertTrue(t.truncated)
        self.assertEqual([r.timestamp for r in t.records], [100, 101, 102])

    def test_log_addresses_max_records_exact(self):
        with patch("subprocess.run", side_effect=_fake_cli(ADDRESS_LINES)):
            t = self.op.log_addresses("./app", max_records=5)
        self.assertFalse(t.truncated)

    def test_log_basic_blocks(self):
        with patch("subprocess.run", side_effect=_fake_cli(BB_LINES)):
            t = self.op.log_basic_blocks("./app")
        self.assertEqual([r.basic_block_id for r in t.records], [0, 1, 1])
        self.assertEqual(t.records[0].block_idx, (0, 1, 0))
        self.assertEqual(t.records[0].source_file, "/src/k.hip")

    def test_uninstrumented_kernels(self):
        with patch("subprocess.run", side_effect=_fake_cli(EMPTY_JSON, SUMMARY_LOG)):
            r = self.op.analyze_memory("./app")
        self.assertEqual(r.uninstrumented_kernels,
                         {"plain_kernel(int*) [clone .kd]": 2, "other(float*) [clone .kd]": 1})

    def test_memory_access_extra_fields(self):
        payload = json.dumps([{"kernel": "k", "dispatch_id": 1, "unanalyzed_flat_accesses": 3,
                               "accesses": [{"source_file": "a.hip", "line": 1, "column": 2,
                                             "cache_lines_needed": 8, "cache_lines_used": 12,
                                             "excess_cache_lines": 4, "isa_instruction": "global_load_dword",
                                             "ir_bytes": 4, "isa_bytes": 4, "bank_conflicts": 0}]}])
        with patch("subprocess.run", side_effect=_fake_cli(payload)):
            r = self.op.analyze_memory("./app")
        k = r.kernels[0]
        a = k.accesses[0]
        self.assertEqual(k.unanalyzed_flat_accesses, 3)
        self.assertEqual((a.cache_lines_needed, a.cache_lines_used, a.isa_instruction, a.ir_bytes, a.isa_bytes),
                         (8, 12, "global_load_dword", 4, 4))
        self.assertEqual(r.uninstrumented_kernels, {})


if __name__ == "__main__":
    unittest.main()

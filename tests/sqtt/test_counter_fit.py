#!/usr/bin/env python3
"""Unit tests for omniprobe/sqtt/counter_fit.py that need no GPU and no decoder.

The decoder-backed parts (marker decoding, clock maps) are stubbed out; what is
tested is the fit itself, the grouping of sites that always run together, and
reading SPM samples whose instances sample on separate timelines (MI300).

Run: python3 tests/sqtt/test_counter_fit.py
"""

import json
import os
import sys
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SQTT = os.path.join(HERE, "..", "..", "omniprobe", "sqtt")


def import_counter_fit():
    """Import counter_fit with the decoder modules replaced by empty stubs."""
    stubs = {
        "decoder_paths": {"add_decoder_paths": lambda: None},
        "address_trace": {"BUFFER_KINDS": set(), "MEMORY_KINDS": set(), "decode_address_traces": None},
        "marker_common": {
            "add_marker_args": None,
            "load_marker_traces": None,
            "marker_selected": None,
            "marker_time": None,
        },
        "rocprof_trace_decoder": {"RecordType": types.SimpleNamespace(REALTIME=0)},
    }
    for name, attrs in stubs.items():
        module = types.ModuleType(name)
        module.__dict__.update(attrs)
        sys.modules[name] = module
    sys.path.insert(0, SQTT)
    import counter_fit

    return counter_fit


cf = import_counter_fit()


class FitTest(unittest.TestCase):
    def test_least_squares_recovers_costs(self):
        # Line A costs 0 per execution, line B costs 31; the mix changes per window.
        rows = [[100, 0], [75, 25], [50, 50], [25, 75], [0, 100], [60, 30]]
        y = [a * 0 + b * 31 for a, b in rows]
        x = cf.solve_least_squares(rows, y)
        self.assertAlmostEqual(x[0], 0.0, places=6)
        self.assertAlmostEqual(x[1], 31.0, places=6)
        self.assertAlmostEqual(cf.relative_residual(rows, y, x), 0.0, places=9)

    def test_sites_that_always_run_together_are_grouped(self):
        # Columns 0 and 1 are proportional (same loop body); column 2 is not.
        rows = [[10, 20, 5], [4, 8, 9], [7, 14, 1], [1, 2, 3]]
        groups = cf.group_collinear(rows, 0.97)
        self.assertIn(sorted([0, 1]), [sorted(g) for g in groups])
        self.assertIn([2], [sorted(g) for g in groups])


class SpmStreamsTest(unittest.TestCase):
    def write_spm(self, records):
        tool = {
            "counters": [{"id": {"handle": 1}, "name": "SQ_INSTS_LDS"}],
            "callback_records": {"spm_counter_collection": [{"records": records}]},
        }
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump({"rocprofiler-sdk-tool": [tool]}, f)
        f.close()
        self.addCleanup(os.remove, f.name)
        return f.name

    def test_instances_on_separate_timelines(self):
        # Two instances (e.g. two XCCs) sampling every 48 ticks, 24 ticks apart.
        records = []
        for k in range(5):
            records.append({"counter_id": {"handle": 1}, "instance_id": 1, "timestamp": 100 + 48 * k, "value": 10.0})
            records.append({"counter_id": {"handle": 1}, "instance_id": 2, "timestamp": 124 + 48 * k, "value": 20.0})
        streams = cf.load_spm_streams(self.write_spm(records), ["SQ_INSTS_LDS"])
        summed, per_instance = streams["SQ_INSTS_LDS"]
        self.assertEqual(len(per_instance), 2)
        self.assertEqual(sorted(len(v) for v in per_instance.values()), [5, 5])
        # Each timestamp belongs to one instance, so totals per stamp are not merged.
        self.assertEqual(len(summed), 10)
        self.assertEqual(sum(summed.values()), 5 * 10.0 + 5 * 20.0)

    def test_shared_timeline_is_summed(self):
        records = [
            {"counter_id": {"handle": 1}, "instance_id": i, "timestamp": 100 + 48 * k, "value": 1.0}
            for k in range(3)
            for i in range(4)
        ]
        summed = cf.load_spm_samples(self.write_spm(records), ["SQ_INSTS_LDS"])["SQ_INSTS_LDS"]
        self.assertEqual(sorted(summed.items()), [(100, 4.0), (148, 4.0), (196, 4.0)])


if __name__ == "__main__":
    unittest.main(verbosity=2)

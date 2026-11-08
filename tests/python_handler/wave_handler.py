"""PythonHandler fixture for the per-wave interface (tests/test_python_handler.sh).

Defines handleAddressWave only, so it also checks that the per-lane
handleAddressMessage is no longer required. Writes one JSON line per dispatch
(from handleReport) to the file named by PYHANDLER_EVIDENCE, listing every wave
message it received with the fields the test checks.
"""

import json
import os

_EVIDENCE = os.environ["PYHANDLER_EVIDENCE"]
_waves = {}


def handleAddressWave(msg):
    _waves.setdefault(msg["dispatch_id"], []).append({
        "file": os.path.basename(msg["source_file"]),
        "line": msg["line"],
        "column": msg["column"],
        "access_type": msg["access_type"],
        "memory_space": msg["memory_space"],
        "access_size": msg["access_size"],
        "n_addresses": len(msg["addresses"]),
        "distinct": len(set(msg["addresses"])),
        "lanes_ok": msg["lanes"] == [l for l in range(64) if msg["exec"] >> l & 1],
        "exec": msg["exec"],
        "block_idx": list(msg["block_idx"]),
        "wave_num": msg["wave_num"],
        "cu_id": msg["cu_id"],
        "timestamp": msg["timestamp"],
        "kernel": msg["kernel"],
    })


def handleReport(msg):
    with open(_EVIDENCE, "a") as fh:
        fh.write(json.dumps({"dispatch_id": msg["dispatch_id"],
                             "waves": _waves.pop(msg["dispatch_id"], [])}) + "\n")

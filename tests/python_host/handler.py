"""PythonHandler fixture for tests/test_python_host.sh.

Counts address lanes and wave messages per dispatch and, once per dispatch
(handleReport), appends one JSON line to $PYHOST_EVIDENCE. It also records
which interpreter it runs in: the Python host sets builtins.PYHOST_MARKER, so
seeing it here means handler and host share one interpreter.
"""

import builtins
import json
import os
import sys

_EVIDENCE = os.environ["PYHOST_EVIDENCE"]
_lanes = {}
_waves = {}


def handleAddressWave(msg):
    d = msg["dispatch_id"]
    _lanes[d] = _lanes.get(d, 0) + len(msg["addresses"])
    _waves[d] = _waves.get(d, 0) + 1


def handleReport(msg):
    d = msg["dispatch_id"]
    with open(_EVIDENCE, "a") as fh:
        fh.write(json.dumps({
            "dispatch_id": d,
            "kernel_dispatch": msg.get("kernel_dispatch"),
            "kernel": msg["kernel"],
            "lanes": _lanes.pop(d, 0),
            "waves": _waves.pop(d, 0),
            "host_marker": getattr(builtins, "PYHOST_MARKER", None),
            "python": sys.version.split()[0],
            "pid": os.getpid(),
        }) + "\n")

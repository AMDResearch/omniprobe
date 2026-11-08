"""PythonHandler fixture for time-interval messages (tests/test_python_handler.sh).

Writes one JSON line per time-interval message to PYHANDLER_EVIDENCE.
"""

import json
import os

_EVIDENCE = os.environ["PYHANDLER_EVIDENCE"]


def handleTimeMessage(msg):
    keep = ("start", "stop", "elapsed_time", "block_id", "line", "column", "exec", "timestamp", "wave_num", "cu_id")
    rec = {k: msg[k] for k in keep}
    rec["has_source_file"] = isinstance(msg["source_file"], str) and len(msg["source_file"]) > 0
    rec["block_idx"] = list(msg["block_idx"])
    with open(_EVIDENCE, "a") as fh:
        fh.write(json.dumps(rec) + "\n")

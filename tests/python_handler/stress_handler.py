"""PythonHandler fixture for tests/test_python_handler.sh.

Does real Python work for every message -- allocates a dict and a string,
appends to a list, updates a dict -- so that any reference-counting or GIL
error in the C++ bridge corrupts the heap quickly instead of hiding.

At handleReport (once per dispatch) it appends one JSON line to the file named
by PYHANDLER_EVIDENCE. Everything the test asserts on comes from these lines,
i.e. from values the Python side computed, never from the bridge's own output.
"""

import json
import os
import sys
import threading
import time
import uuid

# A fresh interpreter would re-import this module and draw a new token, and
# its counters would restart: so one token across every report, with running
# totals that keep growing, shows the interpreter survived every dispatch.
INTERPRETER_TOKEN = uuid.uuid4().hex
_EVIDENCE = os.environ["PYHANDLER_EVIDENCE"]

_per_dispatch = {}   # dispatch_id -> list of (address, tag) tuples
_threads = {}        # dispatch_id -> set of thread idents that delivered messages
_span = {}           # dispatch_id -> [first, last] message time
_total = {"addresses": 0, "reports": 0}


def handleAddressMessage(msg):
    d = msg["dispatch_id"]
    now = time.monotonic()
    record = {"addr": msg["address"], "tag": "a%x" % msg["address"]}
    _per_dispatch.setdefault(d, []).append((record["addr"], record["tag"]))
    _threads.setdefault(d, set()).add(threading.get_ident())
    span = _span.setdefault(d, [now, now])
    span[1] = now
    _total["addresses"] += 1


def handleTimeMessage(msg):
    pass


def handleReport(msg):
    d = msg["dispatch_id"]
    entries = _per_dispatch.pop(d, [])
    addrs = sorted({a for a, tag in entries if tag == "a%x" % a})
    _total["reports"] += 1
    line = {
        "token": INTERPRETER_TOKEN,
        "kernel": msg["kernel"],
        "dispatch_id": d,
        "messages": len(entries),
        "distinct": len(addrs),
        "lowest": hex(addrs[0]) if addrs else None,
        "highest": hex(addrs[-1]) if addrs else None,
        "threads": sorted(_threads.pop(d, set())),
        "span": _span.pop(d, None),
        "total_addresses": _total["addresses"],
        "total_reports": _total["reports"],
        "python": "%d.%d" % sys.version_info[:2],
    }
    with open(_EVIDENCE, "a") as fh:
        fh.write(json.dumps(line) + "\n")

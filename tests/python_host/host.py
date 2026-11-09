"""A Python program that launches instrumented HIP kernels, for
tests/test_python_host.sh: the host process of omniprobe's PythonHandler is
then itself a Python interpreter.

    host.py <mode> <libpy_host_lib.so> <launches> <threads> <loads>

mode: cdll     ctypes.CDLL, which releases the GIL during the call
      pydll    ctypes.PyDLL, which holds the GIL for the whole call, as a C
               extension that does not release it would (launch + sync)
      threads  CDLL, while another Python thread runs bytecode throughout
Prints PYHOST_RC=<library return value> and exits with it.
"""

import builtins
import ctypes
import os
import sys
import threading

mode, lib, launches, threads, loads = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:6])
builtins.PYHOST_MARKER = f"host-{os.getpid()}"

dll = (ctypes.PyDLL if mode == "pydll" else ctypes.CDLL)(lib)
dll.py_host_run.argtypes = [ctypes.c_int] * 3
dll.py_host_run.restype = ctypes.c_int

done = threading.Event()
spins = [0]


def spin():
    while not done.is_set():
        spins[0] += 1


spinner = threading.Thread(target=spin) if mode == "threads" else None
if spinner:
    spinner.start()
rc = dll.py_host_run(launches, threads, loads)
done.set()
if spinner:
    spinner.join()
    print(f"PYHOST_SPINS={spins[0]}")
print(f"PYHOST_RC={rc}", flush=True)
sys.exit(rc)

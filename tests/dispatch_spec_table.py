#!/usr/bin/env python3
"""Check a dispatch-spec parser against tests/dispatch_spec_cases.txt.

    dispatch_spec_table.py python            # omniprobe/api/dispatch_spec.py
    dispatch_spec_table.py cpp <checker>     # src/dispatch_spec.cc via build/tests/dispatch_spec_check

Prints one line per failing case and a final "N/M cases agree" line; exit 0 iff all agree.
"""
import importlib.util
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LIMIT = 300


def load_cases():
    cases = []
    with open(os.path.join(HERE, "dispatch_spec_cases.txt")) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            spec, expected = line.split("\t")
            cases.append(("" if spec == "<empty>" else spec, expected))
    return cases


def expand(text):
    """Test-side notation: n, a-b, a-b:s, comma-separated; '-' = none."""
    if text == "-":
        return []
    out = set()
    for item in text.split(","):
        step = 1
        if ":" in item:
            item, step = item.split(":")
            step = int(step)
        lo, _, hi = item.partition("-")
        out.update(range(int(lo), int(hi or lo) + 1, step))
    return sorted(out)


def python_results(specs):
    path = os.path.join(HERE, "..", "omniprobe", "api", "dispatch_spec.py")
    mod_spec = importlib.util.spec_from_file_location("dispatch_spec", path)
    ds = importlib.util.module_from_spec(mod_spec)
    mod_spec.loader.exec_module(ds)
    results = []
    for s in specs:
        try:
            p = ds.parse(s)
        except ds.DispatchSpecError as e:
            results.append("ERR " + str(e))
            continue
        members = [n for n in range(1, LIMIT + 1) if p.contains(n)]
        results.append("SET " + (",".join(map(str, members)) or "-"))
    return results


def cpp_results(checker, specs):
    out = subprocess.run([checker, str(LIMIT)], input="".join(s + "\n" for s in specs),
                         capture_output=True, text=True, check=True).stdout
    return out.split("\n")[:len(specs)]


def main():
    cases = load_cases()
    specs = [s for s, _ in cases]
    if sys.argv[1] == "python":
        results = python_results(specs)
    else:
        results = cpp_results(sys.argv[2], specs)
    bad = 0
    for (spec, expected), got in zip(cases, results):
        kind, _, rest = expected.partition(" ")
        if kind == "SET":
            ok = got == "SET " + (",".join(map(str, expand(rest))) or "-")
        else:
            ok = got.startswith("ERR ") and rest in got
        if not ok:
            bad += 1
            print(f"FAIL {sys.argv[1]}: {spec!r}: expected {expected!r}, got {got[:200]!r}")
    print(f"{len(cases) - bad}/{len(cases)} cases agree ({sys.argv[1]})")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

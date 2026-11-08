#!/usr/bin/env python3
"""Derive LDS conflict sets from pairwise SQ_LDS_BANK_CONFLICT sweeps.

Input: a directory with one rocprofv3 counter CSV per sweep, named
<width>_<stride>_<read|write>.csv (see run.sh). Each holds 2016 dispatches of
lds_conflict_sets in pair order (0,1), (0,2), ..., (62,63). A pair conflicts
when the counter is nonzero (REPS cycles for one extra pass).

Prints, per width and access kind, the lane groups (conflict sets) from the
256-byte sweep, whether every group is a clique (i.e. the relation really is a
partition), the bank count implied by the 128-byte sweep, and a comparison with
the CDNA1-3 model omniprobe uses. With --cxx, also the groups as a C++
initializer for lds_model_t in src/memory_analysis_handler.cc.
Exit 0 iff all sweeps are complete and every relation is a partition.
"""
import csv
import glob
import os
import sys
from itertools import combinations

REPS = 64
PAIRS = list(combinations(range(64), 2))
CDNA = {
    4: [range(0, 32), range(32, 64)],
    8: [range(0, 16), range(16, 32), range(32, 48), range(48, 64)],
    16: [[*range(0, 4), *range(20, 24)], [*range(4, 8), *range(16, 20)],
         [*range(8, 12), *range(28, 32)], [*range(12, 16), *range(24, 28)],
         [*range(32, 36), *range(52, 56)], [*range(36, 40), *range(48, 52)],
         [*range(40, 44), *range(60, 64)], [*range(44, 48), *range(56, 60)]],
}


def load(path):
    rows = sorted(csv.DictReader(open(path)), key=lambda r: int(r["Dispatch_Id"]))
    rows = [r for r in rows if r["Counter_Name"] == "SQ_LDS_BANK_CONFLICT"]
    if len(rows) != len(PAIRS):
        return None
    return {p: float(r["Counter_Value"]) for p, r in zip(PAIRS, rows)}


def groups(values):
    """Connected components of the conflict graph, and whether each is a clique."""
    parent = list(range(64))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    for (i, j), v in values.items():
        if v > 0:
            parent[find(i)] = find(j)
    comps = {}
    for lane in range(64):
        comps.setdefault(find(lane), []).append(lane)
    comps = sorted(comps.values())
    cliques = all(values[(a, b)] > 0 for c in comps for a, b in combinations(c, 2))
    return comps, cliques


def ranges(lanes):
    out, start = [], lanes[0]
    for a, b in zip(lanes, lanes[1:] + [None]):
        if b != a + 1:
            out.append((start, a + 1))
            start = b
    return out


def main(d, cxx):
    ok = True
    for width in (4, 8, 16):
        for rw in ("read", "write"):
            f256 = os.path.join(d, f"{width}_256_{rw}.csv")
            f128 = os.path.join(d, f"{width}_128_{rw}.csv")
            if not os.path.exists(f256):
                continue
            v256, v128 = load(f256), load(f128) if os.path.exists(f128) else None
            if v256 is None:
                print(f"{width}-byte {rw}: incomplete 256-byte sweep"); ok = False; continue
            comps, cliques = groups(v256)
            per = sorted({v / REPS for v in v256.values() if v > 0})
            print(f"{width}-byte {rw}: {len(comps)} conflict sets of sizes {sorted({len(c) for c in comps})}, "
                  f"extra passes per conflicting pair {per or [0]}"
                  + ("" if cliques else "  NOT A PARTITION (some lanes in one set do not conflict)"))
            ok = ok and cliques
            for c in comps:
                print("    " + " ".join(f"{a}..{b - 1}" for a, b in ranges(c)))
            if v128 is not None:
                n128 = sum(1 for v in v128.values() if v > 0)
                same = n128 and groups(v128)[0] == comps
                print(f"    128-byte stride: {n128} conflicting pairs -> "
                      + ("32 banks (same sets)" if same else
                         "64 or more banks" if n128 == 0 else "UNEXPECTED (sets differ)"))
            expect = sorted(sorted(g) for g in CDNA[width])
            print("    CDNA1-3 model: " + ("matches" if comps == expect else "differs"))
            if cxx:
                print("    C++: {%d, {%s}}," % (width, ", ".join(
                    "{%s}" % ", ".join("{%d, %d}" % r for r in ranges(c)) for c in comps)))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], "--cxx" in sys.argv[2:]))

#!/usr/bin/env python3
"""Compare omniprobe's LDS bank-conflict counts with SQ_LDS_BANK_CONFLICT.

Used by tests/test_lds_bank_conflicts.sh on tests/test_kernels/lds_bank_patterns.cpp.
SQ_LDS_BANK_CONFLICT counts LDS stall cycles caused by bank conflicts; on gfx90a
it equals, per wave and instruction, the extra passes omniprobe counts (measured
2026-11-08), so the comparison is exact. For each access kind (read/write) and
width (4/8 bytes) the script also reports which LDS geometry hypothesis the
hardware matches, so a mismatch says what the handler's model should be.

Usage: lds_bank_check.py <rocprofv3 counter_collection.csv> <omniprobe json>
Exit 0 iff omniprobe equals the hardware for every pattern kernel.
"""
import csv
import json
import sys
from collections import defaultdict

REPS = 16  # pattern accesses per lane per kernel (lds_bank_patterns.cpp)

# name -> (element bytes, lane -> element index); must match lds_bank_patterns.cpp
PATTERNS = {
    "b32_stride1": (4, lambda l: l),
    "b32_stride2": (4, lambda l: 2 * l),
    "b32_split32": (4, lambda l: (l % 32) + 64 * (l // 32)),
    "b32_stride32": (4, lambda l: 32 * l),
    "b32_stride64": (4, lambda l: 64 * l),
    "b32_pad33": (4, lambda l: 33 * l),
    "b32_bcast": (4, lambda l: 0),
    "b64_stride1": (8, lambda l: l),
    "b64_stride2": (8, lambda l: 2 * l),
    "b64_split16": (8, lambda l: (l % 16) + 32 * (l // 16)),
    "b64_split32": (8, lambda l: (l % 32) + 32 * (l // 32)),
    "b64_stride16": (8, lambda l: 16 * l),
    "b64_pad17": (8, lambda l: 17 * l),
    "b128_stride1": (16, lambda l: l),
    "b128_stride8": (16, lambda l: 8 * l),
    "b128_rwsplit": (16, lambda l: 8 * (l // 4) + 4 * ((l // 16) % 2) + (l % 4)),
}
# Added 2026-11-09: sub-dword, 12-byte, read2/write2 (split under-aligned
# elements) and merged pairs. Only omniprobe == hardware is checked for these;
# the hypotheses above describe b32/b64/b128 instructions only.
NEW_PATTERNS = ["b8_stride1", "b8_stride128", "b8_dword4", "b16_stride64",
                "b96_stride1", "b96_stride8", "b96_rwsplit",
                "r2b32_stride1", "r2b32_stride16", "r2b64_stride1", "r2b64_stride8",
                "pair_stride1", "pair_stride16", "pairlines_stride1", "pairlines_stride16"]
ATOMIC_PATTERNS = ["u32_stride1", "u32_bcast", "u32_stride32", "u64_stride1", "u64_stride16",
                   "cas_stride1", "cas_stride16", "f32_stride1", "f32_bcast",
                   "cas64_stride1", "cas64_stride8", "f64_stride16"]


def phases(lanes_per_phase):
    return [range(s, s + lanes_per_phase) for s in range(0, 64, lanes_per_phase)]


def groups(*ranges_per_group):
    return [[lane for a, b in g for lane in range(a, b)] for g in ranges_per_group]


# The models in src/memory_analysis_handler.cc (lds_model), measured with
# tests/lds_conflict_sets: (width, read|write) -> (banks, lane groups per phase).
CDNA = {
    (4, "read"): (32, phases(32)), (4, "write"): (32, phases(32)),
    (8, "read"): (32, phases(16)), (8, "write"): (32, phases(16)),
    (16, "read"): (32, groups(*[((a, a + 4), (b, b + 4)) for h in (0, 32) for a, b in
                                ((h, h + 20), (h + 4, h + 16), (h + 8, h + 28), (h + 12, h + 24))])),
    (16, "write"): (32, phases(8)),
}
CDNA4 = dict(CDNA)
CDNA4[(8, "read")] = (64, phases(32))
CDNA4[(16, "read")] = (64, groups(((0, 4), (12, 16), (20, 28)), ((4, 12), (16, 20), (28, 32)),
                                  ((32, 36), (44, 48), (52, 60)), ((36, 44), (48, 52), (60, 64))))
HYPOTHESES = {"CDNA1-3 (gfx90a)": CDNA, "CDNA4 (gfx950)": CDNA4}


def predict(hypothesis, pattern, rw):
    """Extra passes per wave and instruction: per phase, max distinct dwords in a bank - 1."""
    width, index = PATTERNS[pattern]
    banks, lane_groups = HYPOTHESES[hypothesis][(width, rw)]
    total = 0
    for group in lane_groups:
        per_bank = defaultdict(set)
        for lane in group:
            first = index(lane) * width // 4
            for dword in range(first, first + width // 4):
                per_bank[dword % banks].add(dword)
        total += max(len(d) for d in per_bank.values()) - 1
    return total


def main(counter_csv, omniprobe_json):
    hw = defaultdict(dict)
    for row in csv.DictReader(open(counter_csv)):
        hw[row["Kernel_Name"].split("(")[0]][row["Counter_Name"]] = float(row["Counter_Value"])
    om = {}
    for dispatch in json.load(open(omniprobe_json)):
        name = dispatch["kernel"].split("(")[0]
        om[name] = sum(a["bank_conflicts"] for a in dispatch["accesses"] if a["memory_space"] == "lds")

    ok = True
    print(f"{'kernel':22s} {'hw':>6s} {'omniprobe':>9s}   predicted: " + " | ".join(HYPOTHESES))
    fits = defaultdict(lambda: set(HYPOTHESES))
    for rw in ("read", "write", "atomic"):
        for pattern in (ATOMIC_PATTERNS if rw == "atomic" else list(PATTERNS) + NEW_PATTERNS):
            width = PATTERNS[pattern][0] if pattern in PATTERNS else None
            kernel = f"{rw}_{pattern}"
            if kernel not in hw or "SQ_LDS_BANK_CONFLICT" not in hw[kernel] or not hw[kernel].get("SQ_WAVES"):
                print(f"{kernel:22s} no hardware counter value")
                ok = False
                continue
            waves = hw[kernel]["SQ_WAVES"]
            hw_per = hw[kernel]["SQ_LDS_BANK_CONFLICT"] / (waves * REPS)
            om_per = om[kernel] / (waves * REPS) if kernel in om else None
            preds = {h: predict(h, pattern, rw) for h in HYPOTHESES} if width else {}
            for h, p in preds.items():
                if p != hw_per:
                    fits[(rw, width)].discard(h)
            match = om_per is not None and om_per == hw_per
            ok = ok and match
            om_s = "missing" if om_per is None else f"{om_per:g}"
            print(f"{kernel:22s} {hw_per:6g} {om_s:>9s}   "
                  + " | ".join(f"{preds[h]:g}" if h in preds else "-" for h in HYPOTHESES)
                  + ("" if match else "   <-- omniprobe differs from hardware"))
    print()
    for (rw, width), hs in sorted(fits.items()):
        print(f"hardware, {rw} {width}-byte: " + ("; ".join(sorted(hs)) if hs else "no hypothesis fits"))
    print("omniprobe equals SQ_LDS_BANK_CONFLICT for every kernel" if ok
          else "omniprobe differs from SQ_LDS_BANK_CONFLICT")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))

#!/bin/bash
# Measure LDS conflict sets on the GPU present: for every pair of lanes, does
# an access by only those two lanes to one bank conflict? (Rene's method.)
#   tests/lds_conflict_sets/run.sh [build dir] [output dir]
# Needs rocprofv3 and lds_conflict_sets from the build (tests/test_kernels).
# Sweeps b32/b64/b128 x read/write at 256-byte stride (same bank for 32 or 64
# banks) and 128-byte stride (same bank only for 32), one process per sweep with
# one dispatch per pair; then re-measures a few pairs one process each, to show
# the in-process sweep is equivalent. Prints the conflict sets (analyze.py).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${1:-$HERE/../../build}"
OUT="${2:-$HERE/../test_output/lds_conflict_sets}"
BIN="$BUILD/tests/test_kernels/lds_conflict_sets"
ROCPROF="${ROCM_PATH:-/opt/rocm-7.2.0}/bin/rocprofv3"
[ -x "$BIN" ] || { echo "missing $BIN"; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"; cd "$OUT" || exit 1 # rocprofv3 leaves .rocprofv3/ in its cwd
echo "GPU: $(rocminfo 2>/dev/null | sed -n 's/^ *Name: *\(gfx[0-9a-z]*\) *$/\1/p' | head -1)"

prof() { # <name> <args...>: SQ_LDS_BANK_CONFLICT csv for one process -> $OUT/<name>.csv
    local name="$1"; shift
    "$ROCPROF" --pmc SQ_LDS_BANK_CONFLICT -d "$OUT/p_$name" -o r --output-format csv \
        -- "$BIN" "$@" > "$OUT/p_$name.log" 2>&1 || { echo "rocprofv3 failed: $*"; return 1; }
    cp "$OUT/p_$name/r_counter_collection.csv" "$OUT/$name.csv"
}
for w in 4 8 16; do for s in 256 128; do for rw in read write; do
    prof "${w}_${s}_${rw}" "$w" "$s" "$rw" all || exit 1
done; done; done

echo "== spot check: one process per pair vs the in-process sweep"
spot_ok=1
for spec in "4 256 read 0 1" "4 256 read 0 32" "4 256 write 31 32" "8 256 read 0 15" "8 256 read 15 16" \
            "16 256 read 0 20" "16 256 read 0 4" "16 256 write 0 4" "16 256 write 0 20" "4 128 read 0 5"; do
    set -- $spec
    prof spot "$@" || exit 1
    single="$(python3 -I -c 'import csv,sys; print(float(next(r for r in csv.DictReader(open(sys.argv[1])) if r["Counter_Name"]=="SQ_LDS_BANK_CONFLICT")["Counter_Value"]))' "$OUT/spot.csv")"
    swept="$(python3 -I -c '
import csv, sys
from itertools import combinations
i, j = int(sys.argv[2]), int(sys.argv[3])
rows = sorted((r for r in csv.DictReader(open(sys.argv[1])) if r["Counter_Name"] == "SQ_LDS_BANK_CONFLICT"), key=lambda r: int(r["Dispatch_Id"]))
print(float(rows[list(combinations(range(64), 2)).index((i, j))]["Counter_Value"]))' "$OUT/${1}_${2}_${3}.csv" "$4" "$5")"
    [ "$single" = "$swept" ] && m=same || { m=DIFFERENT; spot_ok=0; }
    echo "  $spec: one process $single, sweep $swept ($m)"
done

echo "== conflict sets"
python3 -I "$HERE/analyze.py" "$OUT" --cxx
rc=$?
[ "$spot_ok" -eq 1 ] || rc=1
exit $rc

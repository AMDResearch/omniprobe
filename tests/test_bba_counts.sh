#!/bin/bash
################################################################################
# BasicBlockAnalysis reports counts and source lines that match the analytic
# answer for a kernel with known control flow, with stable block identities.
#
# Regression test for bf_bba-hardening phase 2. BBA used to identify blocks by
# indexing kernelDB's ISA-derived block table with the BBStart plugin's IR block
# number (which does not match it), attributed them to the wrong source lines,
# numbered them in pointer order (different on every run), and reported
# "cycles" dominated by instrumentation overhead.
#
# bb_counts_test: 1024 threads; a conditional store taken by 1 in 4 lanes; a
# non-unrolled loop whose trip count is a kernel argument. Expected, with E the
# number of waves (entries of the kernel's first block):
#   line BB_LINE_ENTRY    visits E,        lanes 1024
#   line BB_LINE_QUARTER  visits E,        lanes 256
#   line BB_LINE_LOOP     visits trips*E,  lanes trips*1024
#
# This script must never print the string that run_all_tests.sh treats as a
# whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

BIN="${BUILD_DIR}/tests/test_kernels/bb_counts_test"
SRC="${SCRIPT_DIR}/test_kernels/bb_counts_test.cpp"
if [ ! -x "$BIN" ]; then
    echo -e "${RED}ERROR: test kernel not found: $BIN${NC}"
    exit 1
fi

OUT="$OUTPUT_DIR/bba_counts"
mkdir -p "$OUT"

line_of() { grep -n "// $1\$" "$SRC" | cut -d: -f1; }
L_ENTRY="$(line_of BB_LINE_ENTRY)"
L_QUARTER="$(line_of BB_LINE_QUARTER)"
L_LOOP="$(line_of BB_LINE_LOOP)"

echo "================================================================================"
echo "BasicBlockAnalysis counts (lines: entry $L_ENTRY, quarter $L_QUARTER, loop $L_LOOP)"
echo "================================================================================"

run_bba() {   # run_bba <name> <trips> -> $OUT/<name>.json
    rm -f "$OUT/$1.json"
    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$OMNIPROBE" -i -a BasicBlockAnalysis \
        -t json -o "$OUT/$1.json" -- "$BIN" "$2" > "$OUT/$1.log" 2>&1
}

check() {     # check <name> <python verdict script> <args...>
    local name="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $name"
    local verdict
    verdict="$(python3 "$@" 2>&1 | tail -3)"
    if [[ "$verdict" == OK* ]]; then
        echo -e "  ${GREEN}✓ PASS${NC} - $verdict"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - $verdict"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

COUNTS_PY='
import json, os, sys
path, trips, l_entry, l_quarter, l_loop, src = sys.argv[1], int(sys.argv[2]), *map(int, sys.argv[3:6]), sys.argv[6]
try:
    data = json.load(open(path))
    blocks = [b for k in data if "bb_counts_kernel" in k["kernel"] for b in k["basic_blocks"]]
except Exception as e:
    print(f"BAD output unusable: {e}"); sys.exit()
if any("cycles" in key for b in blocks for key in b):
    print("BAD a timing field is still reported"); sys.exit()
def at(line):
    m = [b for b in blocks if b["line"] == line]
    return m[0] if len(m) == 1 else None
e, q, l = at(l_entry), at(l_quarter), at(l_loop)
if not (e and q and l):
    summary = [(b["line"], b["wave_visits"]) for b in blocks]
    print(f"BAD expected exactly one block at each of lines {l_entry},{l_quarter},{l_loop}; got {summary}"); sys.exit()
waves = e["wave_visits"]
want = {"entry": (waves, 1024), "quarter": (waves, 256), "loop": (trips * waves, trips * 1024)}
got = {"entry": (e["wave_visits"], e["active_lanes"]), "quarter": (q["wave_visits"], q["active_lanes"]),
       "loop": (l["wave_visits"], l["active_lanes"])}
if waves == 0 or got != want:
    print(f"BAD (visits, lanes) got {got}, want {want}"); sys.exit()
bad_src = [b["source_file"] for b in (e, q, l) if os.path.basename(b["source_file"]) != os.path.basename(src)]
if bad_src:
    print(f"BAD source_file not resolved to {os.path.basename(src)}: {bad_src}"); sys.exit()
print(f"OK {waves} waves; (visits, lanes) {got}")
'

run_bba trips5_a 5
run_bba trips5_b 5
run_bba trips3 3

check "counts_match_analytic_trips5" -c "$COUNTS_PY" "$OUT/trips5_a.json" 5 "$L_ENTRY" "$L_QUARTER" "$L_LOOP" "$SRC"
check "counts_match_analytic_trips3" -c "$COUNTS_PY" "$OUT/trips3.json" 3 "$L_ENTRY" "$L_QUARTER" "$L_LOOP" "$SRC"
check "identical_runs_identical_blocks" -c '
import json, sys
def key(p):
    return [(b["basic_block_id"], b["source_file"], b["line"], b["column"], b["wave_visits"], b["active_lanes"])
            for k in json.load(open(p)) for b in k["basic_blocks"]]
try:
    a, b = key(sys.argv[1]), key(sys.argv[2])
except Exception as e:
    print(f"BAD output unusable: {e}"); sys.exit()
print(f"OK {len(a)} blocks, identical" if a == b and a else f"BAD runs differ:\n{a}\n{b}")
' "$OUT/trips5_a.json" "$OUT/trips5_b.json"

print_summary

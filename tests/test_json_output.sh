#!/bin/bash
################################################################################
# File output integrity: every analyzer's -o/-l file must parse, and a run must
# replace the file rather than add to it.
#
# Regression test for bf_json-output-integrity. Three defects, all of which left
# a JSON file that json.load rejects while omniprobe exited 0:
#
#   1. BasicBlockAnalysis wrote one bare {...} per dispatch with no separator,
#      so any run with more than one dispatch produced "[ {..} {..} ]".
#   2. MemoryAnalysis chose "[" versus "," by dispatch_id == 1. Dispatch ids
#      count every dispatch, so when -k filtered out the first kernel the file
#      began with "," and the finalizer could not repair it.
#   3. Every handler opens its output in append mode and nothing truncated the
#      file at the start of a run, so a second run to the same -o gave "[..][..".
#
# Every check parses the file with Python's json module and counts entries:
# a check that only greps for brackets passes on all three defects.
#
# Heatmap and AddressLogger write JSON Lines (one object per line), not an
# array; they are checked line by line.
#
# This script must never print the string that run_all_tests.sh treats as a
# whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

DUAL="${BUILD_DIR}/tests/test_kernels/dual_kernel_test"
DUAL_BB="${BUILD_DIR}/tests/test_kernels/dual_kernel_bbstart_test"
for k in "$DUAL" "$DUAL_BB"; do
    if [ ! -x "$k" ]; then
        echo -e "${RED}ERROR: test kernel not found: $k${NC}"
        echo "Build the test kernels first (cmake --build build)."
        exit 1
    fi
done

mkdir -p "$OUTPUT_DIR"
OUT="$OUTPUT_DIR/json_output"
mkdir -p "$OUT"

echo "================================================================================"
echo "Output file integrity (-t json -o / -l)"
echo "================================================================================"
echo "Omniprobe:      $OMNIPROBE"
echo "AddressMessages: $DUAL"
echo "BBStart:        $DUAL_BB"
echo "================================================================================"

# op <outfile> <logfile> <omniprobe args...> -- run omniprobe, log to <logfile>
op() {
    local log="$1"; shift
    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$OMNIPROBE" "$@" > "$log" 2>&1
}

# check_array <name> <file> <expected count> [<kernel substring that every entry must contain>]
check_array() {
    local name="$1" file="$2" want="$3" kern="${4:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $name"
    local verdict
    verdict="$(python3 - "$file" "$want" "$kern" <<'PY'
import json, sys
path, want, kern = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    data = json.load(open(path))
except Exception as e:
    print(f"BAD does not parse: {e}")
    sys.exit()
if not isinstance(data, list):
    print(f"BAD top level is {type(data).__name__}, not a list")
    sys.exit()
if len(data) != want:
    print(f"BAD {len(data)} entries, expected {want}")
    sys.exit()
if kern and not all(kern in str(d.get("kernel", "")) for d in data):
    print(f"BAD an entry is not for {kern}: {[d.get('kernel') for d in data]}")
    sys.exit()
print(f"OK {len(data)} entries")
PY
)"
    if [[ "$verdict" == OK* ]]; then
        echo -e "  ${GREEN}✓ PASS${NC} - $verdict"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - $verdict"
        echo "  Output saved to: $file"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# check_lines <name> <file> <expected line count> -- JSON Lines: each line parses
check_lines() {
    local name="$1" file="$2" want="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $name"
    local verdict
    verdict="$(python3 - "$file" "$want" <<'PY'
import json, sys
path, want = sys.argv[1], int(sys.argv[2])
try:
    lines = [l for l in open(path).read().splitlines() if l.strip()]
except Exception as e:
    print(f"BAD cannot read: {e}")
    sys.exit()
for i, l in enumerate(lines, 1):
    try:
        json.loads(l)
    except Exception as e:
        print(f"BAD line {i} does not parse: {e}")
        sys.exit()
if want >= 0 and len(lines) != want:
    print(f"BAD {len(lines)} lines, expected {want}")
    sys.exit()
print(f"OK {len(lines)} lines")
PY
)"
    if [[ "$verdict" == OK* ]]; then
        echo -e "  ${GREEN}✓ PASS${NC} - $verdict"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - $verdict"
        echo "  Output saved to: $file"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

count_lines() { grep -c . "$1" 2>/dev/null || echo 0; }

################################################################################
# MemoryAnalysis
################################################################################
f="$OUT/ma_all.json"; rm -f "$f"
op "$OUT/ma_all.log" -i -a MemoryAnalysis -t json -o "$f" -- "$DUAL"
check_array "memory_analysis_two_kernels" "$f" 2

f="$OUT/ma_beta.json"; rm -f "$f"
op "$OUT/ma_beta.log" -i -a MemoryAnalysis -k kernel_beta -t json -o "$f" -- "$DUAL"
check_array "memory_analysis_first_kernel_filtered_out" "$f" 1 kernel_beta

f="$OUT/ma_twice.json"; rm -f "$f"
op "$OUT/ma_twice1.log" -i -a MemoryAnalysis -t json -o "$f" -- "$DUAL"
op "$OUT/ma_twice2.log" -i -a MemoryAnalysis -t json -o "$f" -- "$DUAL"
check_array "memory_analysis_second_run_replaces_file" "$f" 2

f="$OUT/ma_junk.json"; printf 'not json at all\n' > "$f"
op "$OUT/ma_junk.log" -i -a MemoryAnalysis -t json -o "$f" -- "$DUAL"
check_array "memory_analysis_preexisting_file_replaced" "$f" 2

################################################################################
# BasicBlockAnalysis (needs a BBStart-instrumented binary)
################################################################################
f="$OUT/bba_all.json"; rm -f "$f"
op "$OUT/bba_all.log" -i -a BasicBlockAnalysis -t json -o "$f" -- "$DUAL_BB"
check_array "basic_block_analysis_two_kernels" "$f" 2

f="$OUT/bba_beta.json"; rm -f "$f"
op "$OUT/bba_beta.log" -i -a BasicBlockAnalysis -k kernel_beta -t json -o "$f" -- "$DUAL_BB"
check_array "basic_block_analysis_first_kernel_filtered_out" "$f" 1 kernel_beta

f="$OUT/bba_twice.json"; rm -f "$f"
op "$OUT/bba_twice1.log" -i -a BasicBlockAnalysis -t json -o "$f" -- "$DUAL_BB"
op "$OUT/bba_twice2.log" -i -a BasicBlockAnalysis -t json -o "$f" -- "$DUAL_BB"
check_array "basic_block_analysis_second_run_replaces_file" "$f" 2

################################################################################
# JSON Lines analyzers: each line parses, and a second run replaces the file.
# The expected count is taken from a fresh single run, so these do not depend
# on how many messages a kernel happens to emit.
################################################################################
for a in Heatmap AddressLogger; do
    lc="$(echo "$a" | tr '[:upper:]' '[:lower:]')"
    f1="$OUT/${lc}_once.json"; rm -f "$f1"
    op "$OUT/${lc}_once.log" -i -a "$a" -t json -o "$f1" -- "$DUAL"
    once="$(count_lines "$f1")"
    check_lines "${lc}_two_kernels_json_lines" "$f1" -1

    f="$OUT/${lc}_beta.json"; rm -f "$f"
    op "$OUT/${lc}_beta.log" -i -a "$a" -k kernel_beta -t json -o "$f" -- "$DUAL"
    check_lines "${lc}_first_kernel_filtered_out_json_lines" "$f" -1

    f="$OUT/${lc}_twice.json"; rm -f "$f"
    op "$OUT/${lc}_twice1.log" -i -a "$a" -t json -o "$f" -- "$DUAL"
    op "$OUT/${lc}_twice2.log" -i -a "$a" -t json -o "$f" -- "$DUAL"
    check_lines "${lc}_second_run_replaces_file" "$f" "$once"
done

################################################################################
# CSV to a file (-l) is replaced too, not appended to
################################################################################
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} csv_log_location_second_run_replaces_file"
f="$OUT/addresslogger.csv"; rm -f "$f"
op "$OUT/csv1.log" -i -a AddressLogger -l "$f" -- "$DUAL"
once="$(count_lines "$f")"
op "$OUT/csv2.log" -i -a AddressLogger -l "$f" -- "$DUAL"
twice="$(count_lines "$f")"
if [ "$once" -gt 0 ] && [ "$once" -eq "$twice" ]; then
    echo -e "  ${GREEN}✓ PASS${NC} - $twice lines after two runs, same as one run"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - $once lines after one run, $twice after two"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# CSV files are CSV: no JSON rows, and only headers for the rows present.
# AddressLogger used to interleave a JSON line after every CSV row, and
# BasicBlockLogger wrote the address header followed by JSON rows only.
################################################################################
BB_COUNTS="${BUILD_DIR}/tests/test_kernels/bb_counts_test"
for spec in "AddressLogger:$DUAL:ADDRESS_MESSAGE" "BasicBlockLogger:$BB_COUNTS:WAVE_MESSAGE"; do
    IFS=: read -r a bin kind <<< "$spec"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} ${a}_csv_is_csv"
    f="$OUT/${a}.csv"; rm -f "$f"
    op "$OUT/${a}_csv.log" -i -a "$a" -l "$f" -- "$bin"
    verdict="$(python3 - "$f" "$kind" <<'PY'
import csv, sys
path, kind = sys.argv[1], sys.argv[2]
rows = list(csv.reader(open(path)))
if not rows:
    print("BAD empty file"); sys.exit()
json_rows = sum(1 for r in rows if r and r[0].lstrip().startswith("{"))
other = sorted({r[0] for r in rows if r and r[0] != kind})
headers = [r for r in rows if len(r) > 1 and r[1] == "timestamp"]
data = [r for r in rows if r and r[0] == kind and r not in headers]
if json_rows or other or not headers or not data:
    print(f"BAD json rows {json_rows}, unexpected first fields {other}, headers {len(headers)}, {kind} rows {len(data)}")
else:
    print(f"OK {len(data)} {kind} rows, {len(headers)} header(s), no JSON")
PY
)"
    if [[ "$verdict" == OK* ]]; then
        echo -e "  ${GREEN}✓ PASS${NC} - $verdict"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - $verdict"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
done

print_summary

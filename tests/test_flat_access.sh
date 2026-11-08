#!/bin/bash
################################################################################
# MemoryAnalysis analyzes accesses through flat pointers: the instrumentation
# classifies each wave's flat address as global, LDS or scratch at run time.
#
# Regression test for ft_flat-address-classification. Flat accesses (every
# access at -O0; pointers loaded from memory at any level) used to be counted
# as unanalyzed_flat_accesses and nothing more.
#
# flat_access_test (-O2) and flat_access_O0_test (-O0) are one source. Expected:
#   - at -O0, the strided read and the LDS transpose give the same findings as
#     at -O2 (excess cache lines; bank conflicts), with no unanalyzed accesses
#   - a read through a pointer loaded from memory gets cache-line analysis
#   - a wave whose lanes point into different spaces stays unanalyzed
#
# Must never print the string run_all_tests.sh treats as a whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

SRC="${SCRIPT_DIR}/test_kernels/flat_access_test.cpp"
OUT="$OUTPUT_DIR/flat_access"
mkdir -p "$OUT"

echo "================================================================================"
echo "Flat-pointer accesses: MemoryAnalysis at -O0 and through loaded pointers"
echo "================================================================================"

for bin in flat_access_test flat_access_O0_test; do
    check_kernel "${BUILD_DIR}/tests/test_kernels/$bin"
    rm -f "$OUT/$bin.json"
    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" "$OMNIPROBE" -i -a MemoryAnalysis -t json \
        -o "$OUT/$bin.json" -- "${BUILD_DIR}/tests/test_kernels/$bin" > "$OUT/$bin.log" 2>&1
done

check() {     # check <name> <what>
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $1"
    local verdict
    verdict="$(python3 -c "$VERDICT_PY" "$OUT/flat_access_test.json" "$OUT/flat_access_O0_test.json" "$SRC" "$2" 2>&1 | tail -1)"
    if [[ "$verdict" == OK* ]]; then
        echo -e "  ${GREEN}✓ PASS${NC} - $verdict"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - $verdict"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

VERDICT_PY='
import json, re, sys
o2_path, o0_path, src, what = sys.argv[1:5]
marks = {i + 1: m.group(1) for i, l in enumerate(open(src)) for m in [re.search(r"// FLAT_LINE_(\w+)", l)] if m}
def load(p):
    try:
        data = json.load(open(p))
    except Exception as e:
        print(f"BAD output unusable: {e}"); sys.exit()
    out = {}
    for k in data:
        rows = sorted((marks[a["line"]], a["memory_space"], a["access_type"], a.get("excess_cache_lines"), a.get("bank_conflicts"))
                      for a in k["accesses"] if a["line"] in marks)
        out[k["kernel"].split("(")[0]] = (k["unanalyzed_flat_accesses"], rows)
    return out
o2, o0 = load(o2_path), load(o0_path)
def rows(r, kernel, space, access):
    return [x for x in r.get(kernel, (0, []))[1] if x[1] == space and x[2] == access]
if what == "o0_matches_o2":
    for kern in ("strided_read", "transpose_no_pad"):
        if o0.get(kern, (None, None))[1] != o2.get(kern, (None, None))[1]:
            print(f"BAD {kern}: -O0 {o0.get(kern)} != -O2 {o2.get(kern)}"); sys.exit()
    excess = rows(o0, "strided_read", "global", "read")
    conflicts = rows(o0, "transpose_no_pad", "lds", "read")
    if not (excess and excess[0][3] > 0 and conflicts and conflicts[0][4] > 0):
        print(f"BAD findings missing at -O0: strided {excess}, transpose {conflicts}"); sys.exit()
    print(f"OK -O0 == -O2: {excess[0][3]} excess cache lines, {conflicts[0][4]} bank conflicts")
elif what == "o0_nothing_unanalyzed":
    flat = {k: o0.get(k, (None,))[0] for k in ("strided_read", "transpose_no_pad", "ptr_table")}
    print(f"OK no unanalyzed flat accesses at -O0: {flat}" if set(flat.values()) == {0} else f"BAD unanalyzed flat accesses at -O0: {flat}")
elif what == "loaded_pointer_analyzed":
    got, want = rows(o2, "ptr_table", "global", "read"), rows(o2, "strided_read", "global", "read")
    ok = got and want and got[0][3] == want[0][3] and o2["ptr_table"][0] == 0
    print(f"OK read through a loaded pointer: {got[0][3]} excess cache lines, as for the direct strided read" if ok
          else "BAD ptr_table " + str(o2.get("ptr_table")) + ", strided_read read rows " + str(want))
elif what == "mixed_wave_stays_flat":
    bad = [(name, r) for name, r in (("-O2", o2), ("-O0", o0)) if r.get("mixed_spaces", (0, []))[0] < 1 or r["mixed_spaces"][1]]
    print("OK a wave mixing LDS and global stays unanalyzed" if not bad else f"BAD mixed_spaces {bad}")
'

check "o0_matches_o2" o0_matches_o2
check "o0_nothing_unanalyzed" o0_nothing_unanalyzed
check "loaded_pointer_analyzed" loaded_pointer_analyzed
check "mixed_wave_stays_flat" mixed_wave_stays_flat

print_summary

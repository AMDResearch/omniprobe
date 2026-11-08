#!/bin/bash
################################################################################
# A BBInterval-instrumented loop runs to completion and reports real intervals.
#
# Regression test for bf_bb-interval-dynamic-alloca. The plugin created its
# [2 x i64] timestamp buffer with an alloca in every basic block. Outside the
# entry block that is a dynamic alloca: the stack grew on every execution and
# codegen stored and reloaded the slot at different offsets, so every interval
# but the entry block's read start=stop=0, and from 17 loop iterations on the
# kernel faulted ("illegal memory access").
#
# bb_interval_loop_test runs one wave through a loop with a run-time trip count.
# Expected at 10 and at 1000 iterations: exit 0, a time-interval report with a
# non-zero first start, and an interval count that grows by exactly the trip
# count (one interval per block executed; the loop is one block per iteration
# at -O3, plus a fixed number outside it).
#
# Must never print the string run_all_tests.sh treats as a whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

BIN="${BUILD_DIR}/tests/test_kernels/bb_interval_loop_test"
check_kernel "$BIN"
OUT="$OUTPUT_DIR/bb_interval"
mkdir -p "$OUT"

echo "================================================================================"
echo "BBInterval: loop kernel completes with real intervals"
echo "================================================================================"

declare -A EXTRA
for iters in 10 1000; do
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} loop_${iters}_iterations"
    ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" timeout -k 5 120 "$OMNIPROBE" -i -- "$BIN" "$iters" > "$OUT/loop_$iters.log" 2>&1
    status=$?
    intervals="$(sed -n 's/.*total time for all \([0-9]*\) intervals.*/\1/p' "$OUT/loop_$iters.log" | head -1)"
    first="$(sed -n 's/.*first start: \([0-9]*\).*/\1/p' "$OUT/loop_$iters.log" | head -1)"
    if [ "$status" -eq 0 ] && [ -n "$intervals" ] && [ -n "$first" ] && [ "$first" != 0 ]; then
        EXTRA[$iters]=$((intervals - iters))
        echo -e "  ${GREEN}✓ PASS${NC} - exit 0, $intervals intervals, first start $first"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - exit $status, intervals '${intervals}', first start '${first}'; see $OUT/loop_$iters.log"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
done

TESTS_RUN=$((TESTS_RUN + 1))
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} one_interval_per_iteration"
if [ -n "${EXTRA[10]:-}" ] && [ "${EXTRA[10]}" = "${EXTRA[1000]:-x}" ]; then
    echo -e "  ${GREEN}✓ PASS${NC} - intervals = trip count + ${EXTRA[10]} at both trip counts"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - intervals minus trip count: 10 -> '${EXTRA[10]:-}', 1000 -> '${EXTRA[1000]:-}'"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary

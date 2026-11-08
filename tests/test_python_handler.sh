#!/bin/bash
################################################################################
# PythonHandler: a user-written Python module receives every address message of
# many concurrent dispatches, and the run completes.
#
# Regression test for bf_pyhandler-gil. src/pyHandler.cc called the Python
# C-API from dh_comms threads without the GIL (SIGSEGV on the first message),
# finalized the interpreter in every handler's destructor (breaking every later
# dispatch), and released each message's dict twice. Nothing could construct
# the class, so the plugin (libPythonHandler64.so, -a PythonHandler) is new too.
#
# Two runs of python_handler_test, both through the fixture
# python_handler/stress_handler.py, which does real Python work per message and
# writes one JSON line per dispatch (from handleReport):
#   many:       4 streams x 8 launches, 1024 threads, 1 load + 1 store each.
#               Per dispatch: 2048 messages, 2048 distinct addresses.
#   concurrent: 4 streams x 1 launch, 64 threads, 1000 loads + 1 store each,
#               started together at a device barrier. Large enough that each
#               wave flushes its sub-buffer mid-kernel, so four dh_comms threads
#               call into Python at once. Per dispatch: 64064 messages over
#               128 distinct addresses.
# Expected in both: omniprobe and the target exit 0, every dispatch reported
# exactly once with exactly those counts, one interpreter token across all
# reports with running totals that never restart. In the concurrent run, the
# dispatches' message-delivery intervals overlap.
#
# Emits the sentinels the packet's acceptance gate reads: PYHANDLER_ADDR=,
# PYHANDLER_DISPATCHES=, TARGET_STATUS=. Must never print the string
# run_all_tests.sh treats as a whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

BIN="${BUILD_DIR}/tests/test_kernels/python_handler_test"
FIXTURE="${SCRIPT_DIR}/python_handler/stress_handler.py"
check_kernel "$BIN"
if [ ! -f "${OMNIPROBE_ROOT}/lib/libPythonHandler64.so" ] && [ ! -f "${OMNIPROBE_ROOT}/omniprobe/lib/libPythonHandler64.so" ]; then
    echo -e "${RED}ERROR: libPythonHandler64.so not built (Python development files missing at configure time?)${NC}"
    exit 1
fi

OUT="$OUTPUT_DIR/python_handler"
mkdir -p "$OUT"

echo "================================================================================"
echo "PythonHandler: Python work on every message, many and concurrent dispatches"
echo "================================================================================"

STATUS_ALL=0
run_case() {   # run_case <name> <streams> <launches> <threads> <loads> -> $OUT/<name>.{jsonl,log}
    rm -f "$OUT/$1.jsonl"
    PYHANDLER_EVIDENCE="$OUT/$1.jsonl" OMNIPROBE_PYTHON_HANDLER="$FIXTURE" \
        ROCR_VISIBLE_DEVICES="$ROCR_VISIBLE_DEVICES" timeout 600 \
        "$OMNIPROBE" -i -a PythonHandler -- "$BIN" "$2" "$3" "$4" "$5" > "$OUT/$1.log" 2>&1
    local status=$?
    [ "$status" -ne 0 ] && STATUS_ALL=$status
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $1: run_completes"
    if [ "$status" -eq 0 ] && grep -q "python_handler_test: $(($2 * $3)) dispatches, 0 wrong results" "$OUT/$1.log"; then
        echo -e "  ${GREEN}✓ PASS${NC} - exit 0, all results correct"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - exit status $status (139 = SIGSEGV); see $OUT/$1.log"
        tail -5 "$OUT/$1.log" | sed 's/^/    /'
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
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

VERDICT_PY='
import json, sys
path, n_disp, per, distinct = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
what = sys.argv[5]
try:
    lines = [json.loads(l) for l in open(path)]
except Exception as e:
    print(f"BAD evidence unusable: {e}"); sys.exit()
ids = [l["dispatch_id"] for l in lines]
if what == "counts":
    if len(ids) != n_disp or len(set(ids)) != n_disp:
        print(f"BAD {len(ids)} reports for {len(set(ids))} distinct dispatches, want {n_disp}"); sys.exit()
    wrong = [(l["dispatch_id"], l["messages"], l["distinct"]) for l in lines
             if (l["messages"], l["distinct"]) != (per, distinct)]
    if wrong:
        print(f"BAD (dispatch, messages, distinct) != ({per}, {distinct}): {wrong[:5]}"); sys.exit()
    print(f"OK {n_disp} dispatches, each {per} messages at {distinct} distinct addresses")
elif what == "sentinels":
    for l in lines[:2]:
        print("PYHANDLER_ADDR=" + l["lowest"])
        print("PYHANDLER_ADDR=" + l["highest"])
    print(f"PYHANDLER_DISPATCHES={len(set(ids))}")
elif what == "interpreter":
    tokens = {l["token"] for l in lines}
    totals = [(l["total_reports"], l["total_addresses"]) for l in lines]
    if len(tokens) != 1:
        print(f"BAD {len(tokens)} interpreter tokens: the module was re-imported"); sys.exit()
    if [t[0] for t in totals] != list(range(1, len(lines) + 1)):
        print(f"BAD report counter restarted: {[t[0] for t in totals]}"); sys.exit()
    if not lines or totals[-1][1] != n_disp * per:
        print(f"BAD final running total {totals[-1][1] if lines else None}, want {n_disp * per}"); sys.exit()
    print(f"OK one interpreter for {len(lines)} dispatches; running total {totals[-1][1]}")
elif what == "concurrency":
    spans = sorted(tuple(l["span"]) for l in lines if l["span"])
    overlaps = sum(1 for i in range(len(spans)) for j in range(i + 1, len(spans)) if spans[j][0] < spans[i][1])
    threads = {t for l in lines for t in l["threads"]}
    if overlaps == 0:
        print(f"BAD no two dispatches delivered messages at the same time ({len(threads)} threads)"); sys.exit()
    print(f"OK {overlaps} dispatch pairs delivered messages concurrently, on {len(threads)} threads")
'
run_case many 4 8 1024 1
run_case concurrent 4 1 64 1000
echo "TARGET_STATUS=$STATUS_ALL"

check "many: counts_match_analytic" -c "$VERDICT_PY" "$OUT/many.jsonl" 32 2048 2048 counts
check "many: interpreter_survives_dispatches" -c "$VERDICT_PY" "$OUT/many.jsonl" 32 2048 2048 interpreter
check "concurrent: counts_match_analytic" -c "$VERDICT_PY" "$OUT/concurrent.jsonl" 4 64064 128 counts
check "concurrent: interpreter_survives_dispatches" -c "$VERDICT_PY" "$OUT/concurrent.jsonl" 4 64064 128 interpreter
check "concurrent: deliveries_overlap" -c "$VERDICT_PY" "$OUT/concurrent.jsonl" 4 64064 128 concurrency
python3 -c "$VERDICT_PY" "$OUT/many.jsonl" 32 2048 2048 sentinels 2>/dev/null | grep -E '^PYHANDLER_(ADDR|DISPATCHES)='

print_summary

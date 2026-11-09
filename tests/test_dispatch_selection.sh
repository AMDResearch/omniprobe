#!/bin/bash
################################################################################
# -d dispatch selection (ft_dispatch-selection).
#
# Dispatch numbers count per kernel from 1; -d takes all | pattern[:count[:stride]]
# (see omniprobe/api/dispatch_spec.py). Every test banner starts with the
# acceptance criterion it decides ("AC-n:"), which acceptance.sh reads.
#
#   AC-1/AC-2  both parsers agree with tests/dispatch_spec_cases.txt (no GPU)
#   AC-3       the launcher rejects a malformed -d before starting the application
#   AC-4       the runtime rejects a malformed LOGDUR_DISPATCHES set directly
#   AC-5       exactly the expected (kernel, kernel_dispatch) pairs are instrumented
#   AC-6       kernel_dispatch is reported next to the global dispatch_id
#   AC-7       the Python API passes specs through and validates them
#
# This script must never print the string that run_all_tests.sh treats as a
# whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

APP="$BUILD_DIR/tests/test_kernels/dispatch_select_test" # kernel_a, kernel_b alternately, 12 each
CHECKER="$BUILD_DIR/tests/dispatch_spec_check"
WORK="$OUTPUT_DIR/dispatch_selection"
rm -rf "$WORK"; mkdir -p "$WORK"
check_omniprobe

echo "================================================================================"
echo "Dispatch selection (-d)"
echo "================================================================================"

begin() { TESTS_RUN=$((TESTS_RUN + 1)); echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $1"; }
pass() { echo -e "  ${GREEN}✓ PASS${NC} - $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "  ${RED}✗ FAIL${NC} - $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# --- AC-1 / AC-2: the shared case table ------------------------------------
begin "AC-1: python_parser_matches_case_table"
if python3 -I "$SCRIPT_DIR/dispatch_spec_table.py" python > "$WORK/table_python.log" 2>&1; then
    pass "$(tail -1 "$WORK/table_python.log")"
else
    fail "$(grep -c '^FAIL' "$WORK/table_python.log") case(s) disagree; see $WORK/table_python.log"
fi

begin "AC-2: cpp_parser_matches_case_table"
if [ ! -x "$CHECKER" ]; then
    fail "$CHECKER not built"
elif python3 -I "$SCRIPT_DIR/dispatch_spec_table.py" cpp "$CHECKER" > "$WORK/table_cpp.log" 2>&1; then
    pass "$(tail -1 "$WORK/table_cpp.log")"
else
    fail "$(grep -c '^FAIL' "$WORK/table_cpp.log") case(s) disagree; see $WORK/table_cpp.log"
fi

# --- AC-3: the launcher rejects malformed specs, before launching -----------
# ac3 <label> <spec> <expected text>
ac3() {
    begin "AC-3: launcher_rejects_$1"
    local marker="$WORK/ac3_$1.ran" log="$WORK/ac3_$1.log"
    rm -f "$marker"
    "$OMNIPROBE" -i -a MemoryAnalysis -d "$2" -- touch "$marker" > "$log" 2>&1
    local rc=$?
    if [ "$rc" -eq 2 ] && [ ! -e "$marker" ] && grep -qF -- "$3" "$log"; then
        pass "exit 2, '$3', application not started"
    else
        fail "rc=$rc, started=$([ -e "$marker" ] && echo yes || echo no); see $log"
    fi
}
ac3 garbage "5x" "invalid dispatch spec '5x'"
ac3 zero "0" "dispatch numbers start at 1"
ac3 whitespace "1, 2" "whitespace is not allowed"
ac3 random "random" "for sampling use e.g. -d 1::100"

# --- AC-4: an invalid LOGDUR_DISPATCHES reaching the runtime directly -------
# The launcher validates -d, so take its environment (--env-dump) and run the
# application with LOGDUR_DISPATCHES replaced. Before ft_dispatch-selection an
# unrecognised value left the three dispatch flags uninitialised.
begin "AC-4: runtime_rejects_invalid_env_spec"
DUMP="$("$OMNIPROBE" -i -a MemoryAnalysis -t json -o "$WORK/ac4.json" --env-dump -- true 2>/dev/null \
        | grep 'LOGDUR_HANDLERS=' | tail -1)"
rm -f "$WORK/ac4.json"
if [ -z "$DUMP" ]; then
    fail "no environment from --dump-env"
else
    # shellcheck disable=SC2086
    env $DUMP LOGDUR_DISPATCHES=5x "$APP" 2 > "$WORK/ac4.log" 2>&1
    rc=$?
    # Without the launcher nobody closes the JSON array, so count records as text.
    n=$(cat "$WORK/ac4.json" 2>/dev/null | grep -c '"dispatch_id"')
    if grep -q "omniprobe: ERROR: invalid dispatch spec '5x'" "$WORK/ac4.log" && [ "$n" -eq 0 ] && [ "$rc" -eq 0 ]; then
        pass "ERROR reported, 0 dispatches instrumented, application exit 0"
    else
        fail "rc=$rc, instrumented=$n, error message $(grep -q 'invalid dispatch spec' "$WORK/ac4.log" && echo present || echo absent); see $WORK/ac4.log"
    fi
fi

# --- AC-5: which dispatches are instrumented --------------------------------
# pairs <json>: sorted "kernel:kernel_dispatch" of MemoryAnalysis records.
pairs() {
    python3 -I - "$1" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"unreadable: {e}"); sys.exit()
out = []
for d in data:
    k = d.get("kernel", "").split("(")[0]
    out.append(f"{k}:{d.get('kernel_dispatch', 'none')}")
print(" ".join(sorted(out, key=lambda s: (s.split(':')[0], s.split(':')[1].zfill(4)))))
PY
}
# expect <kernels> <numbers>: the pairs string for every kernel x number.
expect() {
    local out="" k n
    for k in $1; do for n in $2; do out="$out $k:$n"; done; done
    echo "${out# }"
}
ac5() {   # ac5 <label> <expected pairs> <omniprobe args...>
    local label="$1" want="$2"; shift 2
    begin "AC-5: selects_$label"
    "$OMNIPROBE" -i -a MemoryAnalysis -t json -o "$WORK/ac5_$label.json" "$@" -- "$APP" > "$WORK/ac5_$label.log" 2>&1
    local rc=$? got
    got="$(pairs "$WORK/ac5_$label.json")"
    if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
        pass "$*: $got"
    else
        fail "$*: rc=$rc"; echo "    want: $want"; echo "    got:  $got"
    fi
}
AB="kernel_a kernel_b"
ac5 all          "$(expect "$AB" "$(seq 1 12)")"            -d all
ac5 default      "$(expect "$AB" "$(seq 1 12)")"
ac5 first        "$(expect "$AB" "1")"                      -d 1
ac5 list         "$(expect "$AB" "2 5")"                    -d 2,5
ac5 list_k       "$(expect kernel_a "2 5")"                 -k kernel_a -d 2,5
ac5 repeat       "$(expect "$AB" "1 3 4 5 7 8 9 11 12")"    -d 1,3,4:3
ac5 stride       "$(expect "$AB" "1 3 7 9")"                -d 1,3:2:6
ac5 every5       "$(expect "$AB" "1 6 11")"                 -d 1::5
ac5 open         "$(expect "$AB" "10 11 12")"               -d 10-
ac5 brackets     "$(expect "$AB" "2 3 4")"                  -d '[2-4]'

# --- AC-6: kernel_dispatch next to dispatch_id ------------------------------
# records <file>: every JSON record (array, or one object per line) as
# "dispatch_id:kernel_dispatch".
records() {
    python3 -I - "$1" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
try:
    data = json.loads(text)
    data = data if isinstance(data, list) else [data]
except Exception:
    data = [json.loads(l) for l in text.splitlines() if l.strip().startswith("{")]
print(" ".join(sorted({f"{d.get('dispatch_id')}:{d.get('kernel_dispatch', 'none')}" for d in data})))
PY
}
for a in Heatmap MemoryAnalysis AddressLogger; do
    begin "AC-6: ${a}_json_reports_kernel_dispatch"
    "$OMNIPROBE" -i -a "$a" -t json -o "$WORK/ac6_$a.json" -d 2 -- "$APP" > "$WORK/ac6_$a.log" 2>&1
    got="$(records "$WORK/ac6_$a.json" 2>&1)"
    # Two dispatches (kernel_a's and kernel_b's second), both kernel_dispatch 2,
    # with global ids that are not 2.
    if [ "$(echo "$got" | wc -w)" -eq 2 ] && ! echo " $got" | grep -qvE '^( [0-9]+:2)+$' && ! echo " $got " | grep -q ' 2:'; then
        pass "dispatch_id:kernel_dispatch = $got"
    else
        fail "dispatch_id:kernel_dispatch = $got"
    fi
done

begin "AC-6: AddressLogger_csv_has_kernel_dispatch_column"
"$OMNIPROBE" -i -a AddressLogger -l "$WORK/ac6.csv" -d 2 -- "$APP" > "$WORK/ac6_csv.log" 2>&1
verdict="$(python3 -I - "$WORK/ac6.csv" <<'PY'
import csv, sys
rows = list(csv.reader(open(sys.argv[1])))
hdr = next((r for r in rows if len(r) > 1 and r[1] == "timestamp"), None)
if not hdr or "kernel_dispatch" not in hdr or hdr.index("kernel_dispatch") != hdr.index("dispatch") + 1:
    print(f"BAD header {hdr}"); sys.exit()
i, j = hdr.index("dispatch"), hdr.index("kernel_dispatch")
data = [r for r in rows if r and r[0] == hdr[0] and r is not hdr and r[1] != "timestamp"]
vals = {(r[i], r[j]) for r in data}
if data and all(kd == "2" and d != "2" for d, kd in vals):
    print(f"OK {len(data)} rows, (dispatch, kernel_dispatch) {sorted(vals)}")
else:
    print(f"BAD {sorted(vals)}")
PY
)"
[[ "$verdict" == OK* ]] && pass "$verdict" || fail "$verdict"

begin "AC-6: stderr_found_line_reports_kernel_dispatch"
if grep -qE "Found instrumented alternative for kernel_a.*\(dispatch [0-9]+, kernel dispatch 2\)" "$WORK/ac6_MemoryAnalysis.log" \
   && grep -qE "Found instrumented alternative for kernel_b.*\(dispatch [0-9]+, kernel dispatch 12\)" "$WORK/ac6_MemoryAnalysis.log"; then
    pass "'Found instrumented alternative for <kernel> (dispatch N, kernel dispatch K)'"
else
    fail "no '(dispatch N, kernel dispatch K)' on the Found lines; see $WORK/ac6_MemoryAnalysis.log"
fi

# --- AC-7: Python API -------------------------------------------------------
begin "AC-7: python_api_dispatches"
verdict="$(PYTHONPATH="$REPO_ROOT" python3 -I - "$OMNIPROBE" "$APP" "$WORK/ac7.ran" <<'PY' 2>&1
import os, sys
sys.path.insert(0, os.environ.get("PYTHONPATH", ""))
from omniprobe.api import Omniprobe
op, app, marker = sys.argv[1], sys.argv[2], sys.argv[3]
probe = Omniprobe(omniprobe_path=op)
res = probe.analyze_memory(app, dispatches="2,5")
got = sorted((k.kernel_name.split("(")[0], k.kernel_dispatch) for k in res.kernels)
want = sorted((k, n) for k in ("kernel_a", "kernel_b") for n in (2, 5))
try:
    probe.analyze_memory(f"touch {marker}", dispatches="random")
    raised = "no ValueError"
except ValueError as e:
    raised = "ValueError" if "1::100" in str(e) else f"ValueError without hint: {e}"
started = os.path.exists(marker)
print("OK" if got == want and raised == "ValueError" and not started else "BAD", got, raised, "started" if started else "not started")
PY
)"
[[ "$verdict" == OK* ]] && pass "$verdict" || fail "$verdict"

print_summary

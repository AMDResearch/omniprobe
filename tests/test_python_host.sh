#!/bin/bash
################################################################################
# PythonHandler when the host program is itself Python (bf_pyhandler-python-host-deadlock).
#
# The handler then runs in the host's interpreter and needs the GIL, which the
# host may hold while it submits GPU work (Triton's launcher does). omniprobe
# used to hold its dispatch lock while waiting for a finished dispatch's
# handler, so a host holding the GIL and launching again deadlocked. Every test
# banner starts with the acceptance criterion it decides ("AC-n:").
#
#   AC-1  Triton host, back-to-back launches
#   AC-2  ctypes PyDLL host (GIL held across launch, sync and memcpy)
#   AC-3  ctypes CDLL host on Python 3.12 and 3.9, buffers filling mid-dispatch
#   AC-4  CDLL host with a busy Python thread
#   AC-5  PyDLL host whose kernel needs the handler while the host holds the GIL:
#         a deadlock by nature; omniprobe must say so instead of hanging silently
#
# Needs a GPU; AC-1 needs TRITON_DIR (a Triton checkout with .venv). This
# script must never print the string that run_all_tests.sh treats as a
# whole-suite skip marker.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

LIB="$BUILD_DIR/tests/test_kernels/libpy_host_lib.so"
HOST="$SCRIPT_DIR/python_host/host.py"
HANDLER="$SCRIPT_DIR/python_host/handler.py"
WORK="$OUTPUT_DIR/python_host"
rm -rf "$WORK"; mkdir -p "$WORK"
check_omniprobe

echo "================================================================================"
echo "PythonHandler in a Python host"
echo "================================================================================"

begin() { TESTS_RUN=$((TESTS_RUN + 1)); echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $1"; }
pass() { echo -e "  ${GREEN}✓ PASS${NC} - $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "  ${RED}✗ FAIL${NC} - $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# run <name> <seconds> <omniprobe args...>: evidence in $WORK/<name>.jsonl,
# output in $WORK/<name>.log, status in RC, wall time in SECS.
run() {
    local name="$1" limit="$2"; shift 2
    local t0=$SECONDS
    PYHOST_EVIDENCE="$WORK/$name.jsonl" OMNIPROBE_PYTHON_HANDLER="$HANDLER" \
        timeout "$limit" "$OMNIPROBE" -i -a PythonHandler "$@" > "$WORK/$name.log" 2>&1
    RC=$?
    SECS=$((SECONDS - t0))
}

# verdict <name> <dispatches> <lanes per dispatch, or "same">
verdict() {
    python3 -I - "$WORK/$1.jsonl" "$2" "$3" <<'PY'
import json, os, sys
path, n, lanes = sys.argv[1], int(sys.argv[2]), sys.argv[3]
recs = [json.loads(l) for l in open(path)] if os.path.exists(path) else []
got = sorted(r["lanes"] for r in recs)
kd = sorted(r["kernel_dispatch"] for r in recs)
in_host = all(r["host_marker"] for r in recs)
ok = (len(recs) == n and kd == list(range(1, n + 1)) and in_host and got[0] > 0
      and (len(set(got)) == 1 if lanes == "same" else got == [int(lanes)] * n))
print(("OK" if ok else "BAD") + f" {len(recs)} reports, lanes {sorted(set(got))}, kernel_dispatch {kd}, "
      f"in host interpreter: {in_host}, python {sorted({r['python'] for r in recs})}")
PY
}

# check <AC: name> <name> <dispatches> <lanes>
check() {
    begin "$1"
    local v; v="$(verdict "$2" "$3" "$4")"
    if [ "$RC" -eq 0 ] && [[ "$v" == OK* ]]; then
        pass "${SECS}s; $v"
    else
        fail "rc=$RC (124 = timed out) after ${SECS}s; $v; see $WORK/$2.log"
    fi
}

# --- AC-1: Triton host ------------------------------------------------------
TPY="${TRITON_DIR:-}/.venv/bin/python"
if [ -x "$TPY" ]; then
    run triton 180 -c "$WORK/triton_cache" -- "$TPY" "$SCRIPT_DIR/python_host/triton_host.py" 3 4096
    check "AC-1: triton_back_to_back_launches" triton 3 same
else
    begin "AC-1: triton_back_to_back_launches"
    fail "TRITON_DIR is not set to a Triton checkout with .venv"
fi

# --- AC-2: GIL held across launch, sync and memcpy ---------------------------
# 2 waves, 10 loads each: nothing fills a buffer while the kernel runs.
run pydll 120 -- python3 "$HOST" pydll "$LIB" 3 128 10
check "AC-2: pydll_host_holding_gil" pydll 3 $((128 * 11))

# --- AC-3: GIL released, buffers filling while the kernel runs --------------
for py in python3.12 python3.9; do
    if command -v "$py" > /dev/null; then
        run "cdll_$py" 180 -- "$py" "$HOST" cdll "$LIB" 3 1024 2000
        check "AC-3: cdll_host_$py" "cdll_$py" 3 $((1024 * 2001))
    else
        begin "AC-3: cdll_host_$py"
        fail "$py not installed"
    fi
done

# --- AC-4: a busy Python thread competes for the GIL ------------------------
run threads 300 -- python3.12 "$HOST" threads "$LIB" 3 1024 200
check "AC-4: cdll_host_with_busy_thread" threads 3 $((1024 * 201))

# --- AC-5: host holds the GIL while the kernel needs the handler ------------
# Cannot finish: the kernel waits for its buffers to be drained, draining runs
# Python, Python needs the GIL, and the host holds it while waiting for the
# kernel. omniprobe must report that rather than hang silently.
begin "AC-5: pydll_host_waiting_on_kernel_is_reported"
run pydll_full 45 -- python3 "$HOST" pydll "$LIB" 1 1024 2000
if grep -q "omniprobe: WARNING: PythonHandler has waited .* for the Python GIL" "$WORK/pydll_full.log"; then
    pass "rc=$RC after ${SECS}s; $(grep -m1 'PythonHandler has waited' "$WORK/pydll_full.log" | cut -c1-120)..."
else
    fail "rc=$RC after ${SECS}s; no 'PythonHandler has waited ... for the Python GIL' warning; see $WORK/pydll_full.log"
fi

print_summary

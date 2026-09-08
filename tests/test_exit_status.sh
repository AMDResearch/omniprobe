#!/bin/bash
################################################################################
# Exit-status propagation through omniprobe.
#
# Regression test for bf_exit-status-not-propagated: capture_subprocess_output
# polled the target to completion and then, under a comment announcing that it
# was about to read the status, read stdout instead. process.returncode was
# never read and main() discarded the call's result, so omniprobe exited 0 no
# matter what happened to the target — including a fatal signal.
#
# That value is load-bearing downstream. omniprobe/api/omniprobe.py has exactly
# one failure check and it tests the value this bug made constant, so a crashed
# run raised nothing and returned an empty-but-well-formed result. The realistic
# damage is a run that dies *after* some dispatches: the result is non-empty,
# non-emptiness assertions pass, and the data is silently truncated.
#
# Two properties of this suite are deliberate and should be preserved:
#
#   * It needs no GPU. Every target is a /bin/sh stub, so this runs on any node.
#     That is unusual for this repository — do not "improve" it into needing a
#     kernel.
#   * Tests 1-3 assert EXACT numbers, never "nonzero". A fix that always exited
#     1 would satisfy "nonzero" while being a different bug wearing this one's
#     clothes, and test 3 is what stops it.
#
# This script must never print the string that run_all_tests.sh:59 treats as a
# whole-suite skip marker — it greps the output for it and would mislabel a
# passing suite.
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_common.sh"

check_omniprobe

# The api package sits beside the omniprobe script itself, in both the source
# tree and an install tree. Resolve the symlink so this works from build/bin.
OP_REAL="$(readlink -f "$OMNIPROBE")"
API_PARENT="$(dirname "$OP_REAL")"

echo "================================================================================"
echo "Exit-status propagation"
echo "================================================================================"
echo "Omniprobe:  $OMNIPROBE"
echo "API path:   $API_PARENT"
echo "================================================================================"

# Run omniprobe over a /bin/sh stub and echo the status omniprobe itself returns.
op_status() {
    "$OMNIPROBE" -i -a MemoryAnalysis -- /bin/sh -c "$1" > /dev/null 2>&1
    echo $?
}

check_status() {
    local name="$1" script="$2" want="$3" why="$4"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} $name"
    local got
    got="$(op_status "$script")"
    if [ "$got" = "$want" ]; then
        echo -e "  ${GREEN}✓ PASS${NC} - $why (got $got)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗ FAIL${NC} - $why: expected exactly $want, got $got"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

################################################################################
# Test 1: a specific nonzero status is propagated verbatim
################################################################################
check_status "exit_status_propagated" 'exit 42' 42 \
    "a target exiting 42 is reported as 42"

################################################################################
# Test 2: a signal death is reported as 128 + signal
#
# Popen reports SIGSEGV as -11. The shell convention is 139, and that is the
# number the API interpolates into its RuntimeError, so it has to be one a
# reader recognises.
################################################################################
check_status "signal_death_propagated" 'kill -SEGV $$' 139 \
    "a target killed by SIGSEGV is reported as 139"

################################################################################
# Test 3: success still exits 0 — the regression guard
################################################################################
check_status "success_still_zero" 'exit 0' 0 \
    "a successful target still yields exit 0"

################################################################################
# Test 4: the API consumer raises rather than returning an empty result
#
# This is the criterion that shows the fix reaches the consumer that depends on
# it; tests 1-3 would pass without it. The API surface is a class, and _run
# splits the command on whitespace, so a quoted `sh -c '...'` cannot survive the
# split — the crashing target has to be a single token, hence a temp script.
################################################################################
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} api_raises_on_crash"

CRASHER="$(mktemp)"
printf '#!/bin/sh\nkill -SEGV $$\n' > "$CRASHER"
chmod +x "$CRASHER"
API_OUT="$OUTPUT_DIR/exit_status_api.out"

AC_API_PARENT="$API_PARENT" AC_OP="$OMNIPROBE" AC_CRASHER="$CRASHER" \
python3 - > "$API_OUT" 2>&1 <<'PY'
import os, sys, traceback
sys.path.insert(0, os.environ["AC_API_PARENT"])
try:
    from api import Omniprobe
except Exception:
    print("IMPORT_FAILED")
    traceback.print_exc()
    sys.exit(0)
try:
    res = Omniprobe(os.environ["AC_OP"]).analyze_memory(os.environ["AC_CRASHER"])
    print("RETURNED:", repr(res)[:300])
except RuntimeError as e:
    print("RAISED_RUNTIMEERROR:", str(e)[:200])
except Exception as e:
    print("RAISED_OTHER:", type(e).__name__, str(e)[:200])
PY
rm -f "$CRASHER"

if grep -q "RAISED_RUNTIMEERROR" "$API_OUT"; then
    echo -e "  ${GREEN}✓ PASS${NC} - API raises RuntimeError on a crashing target"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - API did not raise on a crashing target"
    echo "  Output saved to: $API_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 5: JSON output is still finalized on a failing run
#
# This observes the ordering decision: main() finalizes before exiting, so a run
# that died partway still leaves parseable output. Exiting first would leave no
# file at all and fail here.
################################################################################
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} json_finalized_on_failure"

JOUT="$OUTPUT_DIR/exit_status_failing_run.json"
rm -f "$JOUT"
CRASHER="$(mktemp)"
printf '#!/bin/sh\nkill -SEGV $$\n' > "$CRASHER"
chmod +x "$CRASHER"
"$OMNIPROBE" -i -a MemoryAnalysis -t json -o "$JOUT" -- "$CRASHER" > /dev/null 2>&1
rm -f "$CRASHER"

if [ ! -f "$JOUT" ]; then
    echo -e "  ${RED}✗ FAIL${NC} - no JSON output on a failing run; finalization was skipped"
    TESTS_FAILED=$((TESTS_FAILED + 1))
elif python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$JOUT" 2>/dev/null; then
    echo -e "  ${GREEN}✓ PASS${NC} - JSON output on a failing run is present and parses"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - JSON output on a failing run does not parse"
    echo "  Output saved to: $JOUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

################################################################################
# Test 6: the second caller of capture_subprocess_output does not regress
#
# get_local_isa() calls capture_subprocess_output(["rocminfo"], ...) for ISA
# detection. If the fix ever exits from inside that function instead of
# returning a status, that call kills the interpreter mid-detection. Drive the
# exact call shape with a command that fails and require survival.
#
# The observable is deliberately not "a gfx string appears somewhere":
# get_local_isa is consulted only on the Triton path and a HIP run never prints
# it, so that check fails for reasons unrelated to this defect.
################################################################################
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "\n${YELLOW}[TEST $TESTS_RUN]${NC} isa_detection_caller_survives"

ISA_OUT="$OUTPUT_DIR/exit_status_isa_caller.out"
AC_OP_REAL="$OP_REAL" python3 - > "$ISA_OUT" 2>&1 <<'PY'
import importlib.machinery, importlib.util, os, sys, traceback
spec = importlib.util.spec_from_loader(
    "op_cli",
    importlib.machinery.SourceFileLoader("op_cli", os.environ["AC_OP_REAL"]),
)
try:
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
except Exception:
    print("IMPORT_FAILED")
    traceback.print_exc()
    sys.exit(0)
seen = []
def handler(stream, mask):
    seen.append(stream.readline())
try:
    rc = m.capture_subprocess_output(
        ["/bin/sh", "-c", "echo probe-line; exit 3"], handler=handler, new_env=None
    )
except SystemExit as e:
    print("INTERPRETER_EXITED:", e.code)
    sys.exit(0)
except Exception as e:
    print("RAISED:", type(e).__name__, str(e)[:120])
    sys.exit(0)
print("SURVIVED rc=%r lines=%d" % (rc, len(seen)))
PY

# Assert survival only, not the returned value. This is a regression *guard*: it
# has to pass both before and after the fix, or it cannot tell a fix from a
# break. Tests 1-3 are what assert the status itself.
if grep -q "^SURVIVED" "$ISA_OUT"; then
    echo -e "  ${GREEN}✓ PASS${NC} - capture_subprocess_output returned instead of exiting ($(grep -o 'rc=[^ ]*' "$ISA_OUT"))"
    TESTS_PASSED=$((TESTS_PASSED + 1))
elif grep -q "INTERPRETER_EXITED" "$ISA_OUT"; then
    echo -e "  ${RED}✗ FAIL${NC} - capture_subprocess_output killed the interpreter; this breaks ISA detection"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "  ${RED}✗ FAIL${NC} - could not exercise capture_subprocess_output"
    echo "  Output saved to: $ISA_OUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

print_summary

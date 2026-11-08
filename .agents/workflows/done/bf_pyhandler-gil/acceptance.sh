#!/usr/bin/env bash
#
# acceptance.sh — bf_pyhandler-gil
#
#   bash .agents/workflows/<state>/bf_pyhandler-gil/acceptance.sh
#
# Three deliberate choices:
#
#  1. AC-3 asserts on evidence the PYTHON side writes, never on pyHandler.cc's
#     "Function call to ... succeeded!" print. That print fires whenever
#     PyObject_CallObject returns non-NULL, so `def handleAddressMessage(d): pass`
#     satisfies it completely while ignoring every message.
#  2. AC-4 reads TARGET_STATUS. Since bf_exit-status-not-propagated (c5aec00)
#     omniprobe returns the target's own status, so the test reports omniprobe's
#     (amended 2026-11-08).
#  3. AC-6 makes the plugin-not-core scoping decision observable. It fails if
#     libpython drifts into liblogDuration64.so.
#
# This packet needs a GPU and an architecture-matched build. A wrong-arch binary
# does not error, it silently does not dispatch — so AC-1/AC-2 would report a
# false negative on mismatched hardware. AC-0 guards that.

set -u -o pipefail

AC_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || AC_ROOT=""
[ -z "$AC_ROOT" ] && AC_ROOT="$PWD"

AC_LIB="${AMP_AC_LIB:-$AC_ROOT/.agents/hooks/acceptance-lib.sh}"
if [ ! -f "$AC_LIB" ]; then
  echo "FAIL  SETUP    acceptance library not found at $AC_LIB" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$AC_LIB"

AC_WORKFLOW_ID="bf_pyhandler-gil"
AC_PACKET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AC_DOSSIER_PATH="$AC_PACKET_DIR/dossier.md"

TEST_SCRIPT="$AC_REPO_ROOT/tests/test_python_handler.sh"
TEST_OUT="$(mktemp)"
TEST_RAN=0
trap 'rm -f "$TEST_OUT"' EXIT

if [ -x "$TEST_SCRIPT" ]; then
  bash "$TEST_SCRIPT" >"$TEST_OUT" 2>&1
  TEST_RAN=1
fi

# ---------------------------------------------------------------------------
# The sentinel contract
# ---------------------------------------------------------------------------
#
# tests/test_python_handler.sh must emit these four literals, and nothing else
# in the tree should. They exist because every looser pattern tried here was
# either vacuous or false-FAILing:
#
#   PYHANDLER_ADDR=<hex>        one per address value the PYTHON side received
#   PYHANDLER_DISPATCHES=<n>    distinct dispatches the Python side observed
#   TARGET_STATUS=<n>           the instrumented target's OWN exit status
#
# Anchoring on literals the test emits, rather than on prose describing what it
# did, is what keeps these checks from drifting away from the behaviour.

sentinel() { grep -oE "^$1=[^ ]*" "$TEST_OUT" | head -1 | cut -d= -f2; }

# --- AC-1: a Python module receives at least one address message ---
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-1" "tests/test_python_handler.sh does not exist or is not executable"
elif [ -n "$(sentinel PYHANDLER_ADDR)" ]; then
  ac_pass "AC-1" "the Python handler received address values ($(grep -cE '^PYHANDLER_ADDR=' "$TEST_OUT") reported)"
else
  ac_fail "AC-1" "no PYHANDLER_ADDR= line — no evidence a Python handler received any message"
fi

# --- AC-2: messages from MORE THAN ONE dispatch ---
# This is what catches the per-instance Py_Finalize regression. A single-kernel
# test cannot see it: the interpreter is only torn down after the first handler
# is destroyed, so the first kernel always looks fine.
#
# Compared numerically, not by pattern. An earlier version matched
# /dispatches?[^0-9]*[2-9]/ anywhere in the output, which a run invoked with
# `-d 2` satisfies via its own LOGDUR_DISPATCHES=2 env line while the Python
# side saw exactly one dispatch.
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-2" "no test script — cannot check the multi-dispatch arm"
else
  ND="$(sentinel PYHANDLER_DISPATCHES)"
  if [ -n "$ND" ] && [ "$ND" -ge 2 ] 2>/dev/null; then
    ac_pass "AC-2" "the Python handler saw $ND distinct dispatches"
  elif [ -n "$ND" ]; then
    ac_fail "AC-2" "the Python handler saw only $ND dispatch(es) — the per-instance Py_Finalize regression is invisible below 2"
  else
    ac_fail "AC-2" "no PYHANDLER_DISPATCHES= line — the multi-dispatch arm was not exercised"
  fi
fi

# --- AC-3: evidence is payload VALUES from the Python side ---
# Deliberately NOT a negative grep of the test script for "Function call to".
# That would false-FAIL the moment the test documents why it must not assert on
# that print — and the better the test is commented, the likelier it fires.
# Assert the presence of the right thing instead: real address values, which
# pyHandler.cc's success print cannot produce because it fires for a Python
# function that ignores its argument entirely.
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-3" "no test script — cannot check for Python-authored evidence"
else
  NA="$(grep -cE '^PYHANDLER_ADDR=0x[0-9a-fA-F]+$' "$TEST_OUT")"
  if [ "$NA" -gt 0 ]; then
    ac_pass "AC-3" "$NA address values were written by the Python side (not inferred from a success print)"
  else
    ac_fail "AC-3" "no PYHANDLER_ADDR=0x… values — a run can print 'Function call to … succeeded!' while the Python function ignores every message"
  fi
fi

# --- AC-4: the TARGET's real exit status is 0 ---
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-4" "no test script — cannot check the target's real exit status"
else
  TS="$(sentinel TARGET_STATUS)"
  if [ "$TS" = "0" ]; then
    ac_pass "AC-4" "the instrumented target's own exit status is 0"
  elif [ -n "$TS" ]; then
    ac_fail "AC-4" "the instrumented target exited $TS"
  else
    ac_fail "AC-4" "no TARGET_STATUS= line"
  fi
fi

# --- AC-9 / AC-10 / AC-11 (added 2026-11-08, supervisor) ---
# Each is one named check in tests/test_python_handler.sh; the PASS/FAIL line
# follows its banner. All three fail on the unfixed pyHandler.cc (SIGSEGV).
named_check() {   # named_check <AC> <test name> <what it shows>
  if [ "$TEST_RAN" != 1 ]; then
    ac_fail "$1" "no test script"
  elif grep -A1 -F "$2" "$TEST_OUT" | grep -q "PASS"; then
    ac_pass "$1" "$3"
  else
    ac_fail "$1" "test '$2' did not pass"
  fi
}
named_check "AC-9"  "many: counts_match_analytic" "32 dispatches, each exactly 2048 messages at 2048 distinct addresses, counted by Python"
named_check "AC-10" "concurrent: deliveries_overlap" "several dh_comms threads delivered to Python at the same time"
if grep -A1 -F "concurrent: counts_match_analytic" "$TEST_OUT" | grep -q PASS \
   && grep -A1 -F "many: interpreter_survives_dispatches" "$TEST_OUT" | grep -q PASS \
   && grep -A1 -F "concurrent: interpreter_survives_dispatches" "$TEST_OUT" | grep -q PASS; then
  ac_pass "AC-11" "exact counts under concurrent delivery; one interpreter across every dispatch of both runs"
else
  ac_fail "AC-11" "concurrent counts or interpreter-survival check did not pass"
fi

# --- AC-5: GIL held on every C-API path, released on every exit path ---
ac_judge "AC-5" "src/pyHandler.cc acquires the GIL on every path touching the Python C-API and releases it on every exit path" \
  "this is a claim about all paths through the source, including a throw in the !pDict branch that no test in this packet provokes; AC-1 and AC-2 establish the common paths, the exceptional one is decided by reading the code"

# --- AC-6: the core library did not acquire a libpython dependency ---
# The scoping decision (plugin, not core) made observable. Behavioural: inspect
# the built artifact, not the CMakeLists — a source grep would pass while the
# link line said otherwise.
CORE_LIB="$(ls "$AC_REPO_ROOT"/build/lib/liblogDuration64.so "$AC_REPO_ROOT"/install/omniprobe/lib/liblogDuration64.so 2>/dev/null | head -1)"
if [ -z "$CORE_LIB" ]; then
  ac_fail "AC-6" "liblogDuration64.so not found — build it before this criterion can be decided"
elif ldd "$CORE_LIB" 2>/dev/null | grep -qi python; then
  ac_fail "AC-6" "liblogDuration64.so now links libpython — the fix drifted into the core, reversing an explicit scoping decision"
else
  ac_pass "AC-6" "core library carries no libpython dependency (plugin scoping preserved)"
fi

# --- AC-7 / AC-8: the full suite ---
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-7" "prerequisites absent — full suite not run"
  ac_fail "AC-8" "prerequisites absent — full suite not run"
else
  SUITE_OUT="$(mktemp)"
  bash "$AC_REPO_ROOT/tests/run_all_tests.sh" >"$SUITE_OUT" 2>&1
  SUITE_RC=$?
  # "python" appears nowhere as a suite name in the current runner, so this
  # cannot be satisfied by anything predating the registration.
  # Suite 17 ("Python API end to end") also contains "python", so anchor on
  # the analyzer name (amended 2026-11-08).
  if grep -qE 'Suite [0-9]+:.*PythonHandler' "$SUITE_OUT"; then
    ac_pass "AC-7" "the new suite is registered and actually ran inside run_all_tests.sh"
  else
    ac_fail "AC-7" "no 'Suite N: ...PythonHandler...' banner in the run_all_tests.sh output"
  fi
  if [ "$SUITE_RC" -eq 0 ] && grep -qiE 'Suites skipped:[[:space:]]*0([^0-9]|$)' "$SUITE_OUT"; then
    ac_pass "AC-8" "run_all_tests.sh: exit 0, 0 failed, 0 skipped"
  else
    ac_fail "AC-8" "run_all_tests.sh did not report exit 0 with 0 failed and 0 skipped (rc=$SUITE_RC); see $SUITE_OUT"
  fi
fi

ac_check_write_scope "$AC_DOSSIER_PATH" "SCOPE"

ac_finish

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
#  2. AC-4 checks the TARGET's status, not omniprobe's. omniprobe's exit code is
#     unreliable until bf_exit-status-not-propagated lands, and this packet must
#     not depend on that one.
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

# --- AC-1: a Python module receives at least one address message ---
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-1" "tests/test_python_handler.sh does not exist or is not executable"
elif grep -qiE 'PYHANDLER_EVIDENCE|address message(s)? received' "$TEST_OUT"; then
  ac_pass "AC-1" "the Python handler received at least one address message"
else
  ac_fail "AC-1" "no evidence that a Python handler received any message"
fi

# --- AC-2: messages from MORE THAN ONE dispatch ---
# This is what catches the per-instance Py_Finalize regression. A single-kernel
# test cannot see it: the interpreter is only torn down after the first handler
# is destroyed, so the first kernel always looks fine.
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-2" "no test script — cannot check the multi-dispatch arm"
elif grep -qiE 'dispatches?[^0-9]*([2-9]|[1-9][0-9])\b|2 distinct (kernels|dispatches)' "$TEST_OUT"; then
  ac_pass "AC-2" "the Python handler saw more than one dispatch"
else
  ac_fail "AC-2" "no evidence of more than one dispatch reaching the Python handler — the per-instance Py_Finalize regression would be invisible"
fi

# --- AC-3: evidence written by the Python side, not pyHandler.cc's print ---
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-3" "no test script — cannot check for Python-authored evidence"
elif grep -q "Function call to" "$TEST_SCRIPT" 2>/dev/null; then
  ac_fail "AC-3" "the test asserts on pyHandler.cc's 'Function call to ... succeeded!' print, which fires for a Python function that ignores its argument"
elif grep -qiE 'PYHANDLER_EVIDENCE' "$TEST_OUT"; then
  ac_pass "AC-3" "the test asserts on payload values written by the Python handler"
else
  ac_fail "AC-3" "no Python-authored evidence found in the test output"
fi

# --- AC-4: the TARGET's real exit status is 0 ---
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-4" "no test script — cannot check the target's real exit status"
elif grep -qiE 'target exit(ed)?[^0-9]*0\b|TARGET_STATUS=0' "$TEST_OUT"; then
  ac_pass "AC-4" "the instrumented target's real exit status is 0"
else
  ac_fail "AC-4" "the test does not report the target's own exit status as 0 — do not substitute omniprobe's status here"
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
  if grep -qiE '^.*Suite [0-9]+:.*python' "$SUITE_OUT"; then
    ac_pass "AC-7" "the new suite is registered and actually ran inside run_all_tests.sh"
  else
    ac_fail "AC-7" "no 'Suite N: ...python...' banner in the run_all_tests.sh output"
  fi
  if [ "$SUITE_RC" -eq 0 ] && grep -qiE 'Suites skipped:[[:space:]]*0([^0-9]|$)' "$SUITE_OUT"; then
    ac_pass "AC-8" "run_all_tests.sh: exit 0, 0 failed, 0 skipped"
  else
    ac_fail "AC-8" "run_all_tests.sh did not report exit 0 with 0 failed and 0 skipped (rc=$SUITE_RC); see $SUITE_OUT"
  fi
fi

ac_check_write_scope "$AC_DOSSIER_PATH" "SCOPE"

ac_finish

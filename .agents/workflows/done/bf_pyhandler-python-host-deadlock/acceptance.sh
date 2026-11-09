#!/usr/bin/env bash
#
# acceptance.sh — bf_pyhandler-python-host-deadlock
#
#   bash .agents/workflows/<state>/bf_pyhandler-python-host-deadlock/acceptance.sh [--no-suite]
#
# AC-1..AC-5 are named checks in tests/test_python_host.sh; this script
# reads their PASS/FAIL lines. AC-6 runs the full suite (skip with --no-suite
# while iterating). AC-7 is text presence and reports WEAK at best.
# Needs a GPU and an architecture-matched build/.

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

AC_WORKFLOW_ID="bf_pyhandler-python-host-deadlock"
AC_PACKET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AC_DOSSIER_PATH="$AC_PACKET_DIR/dossier.md"

TEST_SCRIPT="$AC_REPO_ROOT/tests/test_python_host.sh"
TEST_OUT="$(mktemp)"
TEST_RAN=0
trap 'rm -f "$TEST_OUT"' EXIT
if [ -x "$TEST_SCRIPT" ]; then
  bash "$TEST_SCRIPT" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >"$TEST_OUT"
  TEST_RAN=1
fi

# Each AC is a group of tests whose banner starts with "AC-n:"; it passes iff
# the group has at least one test and none failed.
ac_group() {   # ac_group <AC> <what it shows>
  if [ "$TEST_RAN" != 1 ]; then
    ac_fail "$1" "tests/test_python_host.sh does not exist or is not executable"
    return
  fi
  local n f
  n=$(grep -c "\] $1:" "$TEST_OUT")
  f=$(grep -A1 "\] $1:" "$TEST_OUT" | grep -c "FAIL")
  if [ "$n" -gt 0 ] && [ "$f" -eq 0 ]; then
    ac_pass "$1" "$2 ($n checks)"
  else
    ac_fail "$1" "$f of $n checks failed (or none ran); see tests/test_output/dispatch_selection/"
  fi
}
ac_group "AC-1" "Triton host with back-to-back launches finishes with exact reports"
ac_group "AC-2" "ctypes PyDLL host holding the GIL finishes with exact reports"
ac_group "AC-3" "ctypes CDLL hosts on Python 3.12 and 3.9 give exact counts"
ac_group "AC-4" "CDLL host with a busy Python thread gives exact counts"
ac_group "AC-5" "a host holding the GIL while waiting on the kernel is reported, not silent"

# --- AC-6: full suite ---
if [ "${1:-}" = "--no-suite" ]; then
  ac_fail "AC-6" "full suite not run (--no-suite)"
else
  SUITE_OUT="$AC_REPO_ROOT/.untracked/pyhost/full-suite.log"
  mkdir -p "$(dirname "$SUITE_OUT")"
  bash "$AC_REPO_ROOT/tests/run_all_tests.sh" >"$SUITE_OUT" 2>&1
  SUITE_RC=$?
  sed 's/\x1b\[[0-9;]*m//g' "$SUITE_OUT" > "$SUITE_OUT.plain"
  if grep -qE 'Suite [0-9]+: PythonHandler in a Python host' "$SUITE_OUT.plain" \
     && ! grep -qE 'Suite [0-9]+: Random dispatch' "$SUITE_OUT.plain" \
     && grep -qE 'Suites failed:[[:space:]]*0([^0-9]|$)' "$SUITE_OUT.plain"; then
    ac_pass "AC-6" "suite registered, 0 failed (rc=$SUITE_RC; skips: $(grep -E 'Suites skipped' "$SUITE_OUT.plain"))"
  else
    ac_fail "AC-6" "see $SUITE_OUT (rc=$SUITE_RC)"
  fi
fi

# --- AC-7: docs (text presence only) ---
if grep -q "holds the GIL while" "$AC_REPO_ROOT/docs/usage.md" && grep -q "PythonHandler has waited 10 s" "$AC_REPO_ROOT/docs/usage.md"; then
  ac_weak "AC-7" "docs/usage.md documents the host-holds-GIL limitation and its warning (text presence only)"
else
  ac_fail "AC-7" "docs/usage.md lacks the Python-host limitation"
fi

ac_check_write_scope "$AC_DOSSIER_PATH" "SCOPE"
ac_finish

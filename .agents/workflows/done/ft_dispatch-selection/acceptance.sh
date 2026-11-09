#!/usr/bin/env bash
#
# acceptance.sh — ft_dispatch-selection
#
#   bash .agents/workflows/<state>/ft_dispatch-selection/acceptance.sh [--no-suite]
#
# AC-1..AC-7 are named checks in tests/test_dispatch_selection.sh; this script
# reads their PASS/FAIL lines. AC-8 runs the full suite (skip with --no-suite
# while iterating). AC-9 is text presence and reports WEAK at best.
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

AC_WORKFLOW_ID="ft_dispatch-selection"
AC_PACKET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AC_DOSSIER_PATH="$AC_PACKET_DIR/dossier.md"

TEST_SCRIPT="$AC_REPO_ROOT/tests/test_dispatch_selection.sh"
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
    ac_fail "$1" "tests/test_dispatch_selection.sh does not exist or is not executable"
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
ac_group "AC-1" "Python parser agrees with tests/dispatch_spec_cases.txt"
ac_group "AC-2" "C++ parser agrees with tests/dispatch_spec_cases.txt"
ac_group "AC-3" "launcher rejects malformed -d with exit 2 before starting the app"
ac_group "AC-4" "runtime reports an invalid LOGDUR_DISPATCHES and instruments nothing"
ac_group "AC-5" "exactly the expected (kernel, kernel_dispatch) pairs are instrumented"
ac_group "AC-6" "kernel_dispatch is reported next to the global dispatch_id"
ac_group "AC-7" "Python API passes and validates dispatch specs"

# --- AC-8: full suite ---
if [ "${1:-}" = "--no-suite" ]; then
  ac_fail "AC-8" "full suite not run (--no-suite)"
else
  SUITE_OUT="$AC_REPO_ROOT/.untracked/dispatch-selection/full-suite.log"
  mkdir -p "$(dirname "$SUITE_OUT")"
  bash "$AC_REPO_ROOT/tests/run_all_tests.sh" >"$SUITE_OUT" 2>&1
  SUITE_RC=$?
  sed 's/\x1b\[[0-9;]*m//g' "$SUITE_OUT" > "$SUITE_OUT.plain"
  if grep -qE 'Suite [0-9]+: Dispatch selection' "$SUITE_OUT.plain" \
     && ! grep -qE 'Suite [0-9]+: Random dispatch' "$SUITE_OUT.plain" \
     && grep -qE 'Suites failed:[[:space:]]*0([^0-9]|$)' "$SUITE_OUT.plain"; then
    ac_pass "AC-8" "suite registered, random suite gone, 0 failed (rc=$SUITE_RC; skips: $(grep -E 'Suites skipped' "$SUITE_OUT.plain"))"
  else
    ac_fail "AC-8" "see $SUITE_OUT (rc=$SUITE_RC)"
  fi
fi

# --- AC-9: docs (text presence only) ---
U="$AC_REPO_ROOT/docs/usage.md"
if grep -q "1,3,4:3:100" "$U" && grep -q "'\[1,3,4" "$U" && grep -qi "glob" "$U" \
   && grep -qi "multi-GPU\|several GPUs" "$U" && grep -qi "not deterministic\|nondeterministic" "$U" \
   && ! grep -rn "random" "$AC_REPO_ROOT/README.md" "$AC_REPO_ROOT/docs/triton-instrumentation.md" >/dev/null \
   && ! grep -n "random" "$AC_REPO_ROOT/omniprobe/omniprobe" | grep -v "removed" | grep -q .; then
  ac_weak "AC-9" "docs contain the grammar, quoted brackets, glob trap, multi-GPU and determinism notes (text presence only)"
else
  ac_fail "AC-9" "docs/help text check failed"
fi

ac_check_write_scope "$AC_DOSSIER_PATH" "SCOPE"
ac_finish

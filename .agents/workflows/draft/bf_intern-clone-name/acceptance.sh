#!/usr/bin/env bash
#
# acceptance.sh — bf_intern-clone-name
#
#   bash .agents/workflows/<state>/bf_intern-clone-name/acceptance.sh
#
# Two things about this gate are deliberate and should survive editing:
#
#  1. AC-3 exists to catch a fix that repairs the broken path by breaking the
#     working one. The digit-leading-hash case currently succeeds *by accident*
#     (two defects cancelling), and it is the majority of real translation units.
#     A gate that only checked the reported symptom would green-light a change
#     that regresses ~62% of builds.
#
#  2. AC-5 is a vacuity guard. The fixture only tests anything if the toolchain
#     actually emits a `.intern.<hash>` symbol. If a future compiler stops doing
#     that, or `-fgpu-rdc` is dropped from the fixture's flags, every other check
#     here would pass while testing nothing.
#
# The expensive full-suite run (AC-7, AC-8) is skipped when the fixture does not
# yet exist, so a draft-time run of this script is cheap. It is reported as FAIL
# in that case, never as PASS.

set -u -o pipefail

# ---------------------------------------------------------------------------
# Library
# ---------------------------------------------------------------------------

AC_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || AC_ROOT=""
[ -z "$AC_ROOT" ] && AC_ROOT="$PWD"

AC_LIB="${AMP_AC_LIB:-$AC_ROOT/.agents/hooks/acceptance-lib.sh}"
if [ ! -f "$AC_LIB" ]; then
  echo "FAIL  SETUP    acceptance library not found at $AC_LIB" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$AC_LIB"

AC_WORKFLOW_ID="bf_intern-clone-name"
AC_PACKET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AC_DOSSIER_PATH="$AC_PACKET_DIR/dossier.md"

# ---------------------------------------------------------------------------
# Where the deliverables are expected to live
# ---------------------------------------------------------------------------
#
# The exact filenames are an execution-time decision (Open Question 1 decides how
# the two hash flavours are forced). These globs let the gate find the fixture
# under any reasonable name rather than pinning one prematurely.

FIXTURE_SRC="$(ls "$AC_REPO_ROOT"/tests/test_kernels/*intern*.hip 2>/dev/null | head -1)"
TEST_SCRIPT="$(ls "$AC_REPO_ROOT"/tests/*intern*.sh "$AC_REPO_ROOT"/tests/*intern*/run_test.sh 2>/dev/null | head -1)"

TEST_OUT="$(mktemp)"
TEST_RAN=0
trap 'rm -f "$TEST_OUT"' EXIT

if [ -n "$TEST_SCRIPT" ] && [ -x "$TEST_SCRIPT" ]; then
  bash "$TEST_SCRIPT" >"$TEST_OUT" 2>&1
  TEST_RC=$?
  TEST_RAN=1
else
  TEST_RC=127
fi

# --- AC-1: the regression fixture exists and yields a .intern. symbol ---
if [ -z "$FIXTURE_SRC" ]; then
  ac_fail "AC-1" "no regression fixture found matching tests/test_kernels/*intern*.hip"
elif ! grep -q "static __global__\|namespace" "$FIXTURE_SRC"; then
  ac_fail "AC-1" "fixture $FIXTURE_SRC has no internal-linkage kernel (no 'static __global__' and no anonymous namespace)"
elif [ "$TEST_RAN" = 1 ] && grep -qE '\.intern\.[0-9a-f]+' "$TEST_OUT"; then
  ac_pass "AC-1" "fixture present and its build produced a .intern.<hash> symbol"
else
  ac_fail "AC-1" "fixture present but no .intern.<hash> symbol observed in the test output"
fi

# --- AC-2: a letter-leading hash is exercised deterministically ---
# The test must NAME the hash it exercised. A test that merely happens to get a
# letter-leading hash is a coin flip; one that reports which flavour it used can
# be checked, and AC-5 makes the absent case loud.
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-2" "no test script found matching tests/*intern*.sh — cannot check the letter-leading arm"
elif grep -qE '\.intern\.[a-f][0-9a-f]*' "$TEST_OUT"; then
  ac_pass "AC-2" "test output names a letter-leading .intern.<hash>"
else
  ac_fail "AC-2" "test output names no letter-leading .intern.<hash> — the arm that reproduces the defect was not exercised"
fi

# --- AC-3: the digit-leading (currently-working-by-accident) arm too ---
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-3" "no test script found — cannot check the digit-leading anti-regression arm"
elif grep -qE '\.intern\.[0-9][0-9a-f]*' "$TEST_OUT"; then
  ac_pass "AC-3" "test output names a digit-leading .intern.<hash>"
else
  ac_fail "AC-3" "test output names no digit-leading .intern.<hash> — a fix could regress the majority case undetected"
fi

# --- AC-4: every fixture kernel resolves to an instrumented alternative ---
# NOTE: this is a check on a LOG STRING. If the fix changes either message, this
# check must change in the same commit. See dossier § Verification Strategy.
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-4" "no test script found — cannot check instrumented-alternative resolution"
elif grep -q "No instrumented alternative found" "$TEST_OUT"; then
  ac_fail "AC-4" "'No instrumented alternative found' appears in the test output: $(grep -c 'No instrumented alternative found' "$TEST_OUT") occurrence(s)"
elif ! grep -q "Found instrumented alternative" "$TEST_OUT"; then
  ac_fail "AC-4" "no 'Found instrumented alternative' line at all — the run resolved nothing, which is not the same as resolving everything"
else
  ac_pass "AC-4" "all fixture kernels resolved ($(grep -c 'Found instrumented alternative' "$TEST_OUT") found, 0 unresolved)"
fi

# --- AC-5: the vacuity guard is present and fires ---
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-5" "no test script found — cannot check the vacuity guard"
elif grep -qiE 'intern.*(not found|absent|missing)|no .intern. symbol' "$TEST_SCRIPT"; then
  ac_weak "AC-5" "test script contains a guard for a missing .intern. symbol (text presence only — that the guard fires is asserted by inspection, not here)"
else
  ac_fail "AC-5" "test script has no guard against a build with no .intern. symbol; every other check could pass vacuously"
fi

# --- AC-6: registered in the aggregate runner ---
if [ -n "$TEST_SCRIPT" ] && grep -q "$(basename "$(dirname "$TEST_SCRIPT")")\|$(basename "$TEST_SCRIPT")" "$AC_REPO_ROOT/tests/run_all_tests.sh" 2>/dev/null; then
  ac_weak "AC-6" "run_all_tests.sh names the new test (text presence only — that it runs is covered by AC-8)"
else
  ac_fail "AC-6" "the new test is not registered in tests/run_all_tests.sh"
fi

# --- AC-7 / AC-8: the full suite. Skipped as FAIL while the fixture is absent. ---
# Running the whole suite costs several minutes and needs gfx90a hardware plus a
# sourced .untracked/test-env.sh. There is no point paying that before the
# fixture exists, and reporting FAIL (never PASS) keeps the skip honest.
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-7" "prerequisites absent — full suite not run"
  ac_fail "AC-8" "prerequisites absent — full suite not run"
else
  SUITE_OUT="$(mktemp)"
  bash "$AC_REPO_ROOT/tests/run_all_tests.sh" >"$SUITE_OUT" 2>&1
  SUITE_RC=$?
  # The runner prints a tally; require 0 failed and 0 skipped as well as exit 0.
  # 0-skipped matters here because tests/run_all_tests.sh:59 marks a suite skipped
  # on the substring SKIP anywhere in its output, which is easy to trip by accident.
  if [ "$SUITE_RC" -eq 0 ] && grep -qiE 'failed:[[:space:]]*0' "$SUITE_OUT"; then
    ac_pass "AC-7" "pre-existing suites pass — no external-linkage regression"
  else
    ac_fail "AC-7" "run_all_tests.sh reported failures (rc=$SUITE_RC); see $SUITE_OUT"
  fi
  if [ "$SUITE_RC" -eq 0 ] && grep -qiE 'failed:[[:space:]]*0' "$SUITE_OUT" && grep -qiE 'skipped:[[:space:]]*0' "$SUITE_OUT"; then
    ac_pass "AC-8" "run_all_tests.sh: exit 0, 0 failed, 0 skipped"
  else
    ac_fail "AC-8" "run_all_tests.sh did not report exit 0 with 0 failed and 0 skipped (rc=$SUITE_RC); see $SUITE_OUT"
  fi
fi

# --- AC-9: base-commit failure. Not decidable in one hermetic run. ---
ac_judge "AC-9" "the new test fails at the base commit and passes at HEAD" \
  "deciding this requires building and running a second tree at a different commit, which this script cannot do hermetically inside one run; the evidence is recorded in run-log.md and artifacts.md and a human confirms it"

# --- Out-of-scope writes ---
ac_check_write_scope "$AC_DOSSIER_PATH" "SCOPE"

ac_finish

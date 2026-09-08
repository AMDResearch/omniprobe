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
elif ! grep -qE 'static __global__|^namespace[[:space:]]*\{' "$FIXTURE_SRC"; then
  # Anchored deliberately: a bare grep for "namespace" is satisfied by
  # "using namespace std;", which says nothing about internal linkage.
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
#
# This is a check on a LOG STRING, so it has both failure directions.
#
# False FAIL: if the test script echoes its own commentary containing the phrase
# ("checking for 'No instrumented alternative found'..."), an unanchored grep
# reports a defect that is not there. Both patterns are therefore anchored to
# line start, which is where omniprobe emits them (interceptor.cc:792, :806) and
# is not where harness commentary normally sits. The test must not print either
# literal at column 0 in its own output.
#
# Drift: if the fix changes either message, this check must change in the same
# commit. See dossier § Verification Strategy.
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-4" "no test script found — cannot check instrumented-alternative resolution"
elif grep -qE '^No instrumented alternative found' "$TEST_OUT"; then
  ac_fail "AC-4" "'No instrumented alternative found' appears in the test output: $(grep -cE '^No instrumented alternative found' "$TEST_OUT") occurrence(s)"
elif ! grep -qE '^Found instrumented alternative' "$TEST_OUT"; then
  ac_fail "AC-4" "no 'Found instrumented alternative' line at all — the run resolved nothing, which is not the same as resolving everything"
else
  ac_pass "AC-4" "all fixture kernels resolved ($(grep -cE '^Found instrumented alternative' "$TEST_OUT") found, 0 unresolved)"
fi

# --- AC-5: the vacuity guard actually fires ---
#
# Deliberately behavioural. The earlier version of this check grepped the test
# script's source for guard-ish wording, which a comment satisfies — so it could
# have passed against a test with no working guard at all. Instead, drive the
# guard: with AC_FORCE_NO_INTERN=1 the test must simulate a build carrying no
# `.intern.` symbol and must FAIL. A test that still exits 0 under that flag is
# one whose other assertions can pass vacuously.
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-5" "no test script found — cannot check the vacuity guard"
else
  GUARD_OUT="$(mktemp)"
  AC_FORCE_NO_INTERN=1 bash "$TEST_SCRIPT" >"$GUARD_OUT" 2>&1
  GUARD_RC=$?
  if [ "$GUARD_RC" -ne 0 ]; then
    ac_pass "AC-5" "vacuity guard fires: test exits $GUARD_RC when forced to see no .intern. symbol"
  else
    ac_fail "AC-5" "test exits 0 under AC_FORCE_NO_INTERN=1 — it does not detect a build with no .intern. symbol, so its other assertions can pass vacuously"
  fi
  rm -f "$GUARD_OUT"
fi

# --- AC-7 / AC-8 / AC-6: the full suite. Skipped as FAIL while the fixture is absent. ---
#
# Running the whole suite costs several minutes and needs gfx90a hardware plus a
# sourced .untracked/test-env.sh. There is no point paying that before the
# fixture exists, and reporting FAIL (never PASS) keeps the skip honest.
#
# AC-6 is decided from this run rather than by grepping run_all_tests.sh, because
# the obvious grep is a proven vacuous PASS: the pattern built from the test's
# path components ("tests", or "run_test.sh", which already appears five times)
# matches an UNTOUCHED run_all_tests.sh. Verified 2026-09-08 by running it against
# the unmodified file. Requiring the suite banner to appear in a real run cannot
# be satisfied by a file that does not run.
if [ "$TEST_RAN" != 1 ]; then
  ac_fail "AC-6" "prerequisites absent — full suite not run, so registration cannot be observed"
  ac_fail "AC-7" "prerequisites absent — full suite not run"
  ac_fail "AC-8" "prerequisites absent — full suite not run"
else
  SUITE_OUT="$(mktemp)"
  bash "$AC_REPO_ROOT/tests/run_all_tests.sh" >"$SUITE_OUT" 2>&1
  SUITE_RC=$?

  # run_all_tests.sh:40 prints "Suite <n>: <name>" for each registered suite.
  # "intern" appears nowhere in the current file (verified: 0 hits), so this
  # cannot be satisfied by anything that predates the registration.
  if grep -qiE '^.*Suite [0-9]+:.*intern' "$SUITE_OUT"; then
    ac_pass "AC-6" "the new suite is registered and actually ran inside run_all_tests.sh"
  else
    ac_fail "AC-6" "no 'Suite N: ...intern...' banner in the run_all_tests.sh output — the new test is not registered, or did not run"
  fi

  # rc==0 already implies "Suites failed: 0"; the skipped tally is the load-bearing
  # one, because a suite can be marked skipped without affecting the exit code.
  # 0-skipped matters here because run_all_tests.sh:59 marks a suite skipped on the
  # substring SKIP anywhere in its output, which is easy to trip by accident.
  if [ "$SUITE_RC" -eq 0 ]; then
    ac_pass "AC-7" "pre-existing suites pass — no external-linkage regression"
  else
    ac_fail "AC-7" "run_all_tests.sh reported failures (rc=$SUITE_RC); see $SUITE_OUT"
  fi
  if [ "$SUITE_RC" -eq 0 ] && grep -qiE 'Suites skipped:[[:space:]]*0([^0-9]|$)' "$SUITE_OUT"; then
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

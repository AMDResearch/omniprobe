#!/usr/bin/env bash
#
# acceptance.sh — bf_library-filter-chain-silent-pass
#
#   bash .agents/workflows/<state>/bf_library-filter-chain-silent-pass/acceptance.sh
#
# Needs a GPU node with an arch-matched build in <repo>/build and
# .untracked/test-env.sh present (it is sourced here). Before the fix, AC-1..AC-4
# are expected to FAIL — that is the reproduction.

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

AC_WORKFLOW_ID="bf_library-filter-chain-silent-pass"
AC_PACKET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AC_DOSSIER_PATH="$AC_PACKET_DIR/dossier.md"

REPO="$AC_REPO_ROOT"
# shellcheck source=/dev/null
source "$REPO/.untracked/test-env.sh" >/dev/null 2>&1 || true
unset BUILD_DIR OMNIPROBE_ROOT

# Scratch root holding only a copy of the suite: REPO_ROOT inside the script
# then resolves to $S, which has no build/ — the condition that exposed the bug.
new_scratch() {
  local s; s="$(mktemp -d)"
  mkdir -p "$s/tests"
  cp -r "$REPO/tests/library_filter_chain" "$s/tests/"
  rm -rf "$s/tests/library_filter_chain/build" "$s/tests/library_filter_chain/test_output"
  echo "$s"
}

EXPECTED_PLUGIN="$REPO/build/lib/plugins/libAMDGCNSubmitAddressMessages-rocm.so"
if [ ! -f "$EXPECTED_PLUGIN" ]; then
  ac_fail "SETUP" "no built plugin at $EXPECTED_PLUGIN — build <repo>/build first"
  ac_finish
fi

# --- AC-1 / AC-2: no build/ in the script's repo root, valid OMNIPROBE_ROOT ---
S1="$(new_scratch)"
OUT1="$(OMNIPROBE_ROOT="$REPO/build" bash "$S1/tests/library_filter_chain/run_test.sh" 2>&1)"; RC1=$?
if [ "$RC1" -eq 0 ] \
   && grep -q "Test 5 PASSED" <<<"$OUT1" \
   && ! grep -q "skipping omniprobe tests" <<<"$OUT1" \
   && ! grep -q "Building without instrumentation" <<<"$OUT1"; then
  ac_pass "AC-1" "Tests 2-5 ran against OMNIPROBE_ROOT with no build/ in the repo root"
else
  ac_fail "AC-1" "rc=$RC1; Test 5 PASSED present: $(grep -c 'Test 5 PASSED' <<<"$OUT1"); skip/uninstrumented warnings: $(grep -cE 'skipping omniprobe tests|Building without instrumentation' <<<"$OUT1")"
fi

CACHED="$(grep '^INST_PLUGIN:' "$S1/tests/library_filter_chain/build/CMakeCache.txt" 2>/dev/null | cut -d= -f2)"
if [ "$CACHED" = "$EXPECTED_PLUGIN" ]; then
  ac_pass "AC-2" "test libraries instrumented with the plugin from OMNIPROBE_ROOT"
else
  ac_fail "AC-2" "INST_PLUGIN='${CACHED:-<unset>}', expected '$EXPECTED_PLUGIN'"
fi

# --- AC-3: no usable omniprobe tree at all -> must fail, without 'SKIP' ---
S3="$(new_scratch)"
OUT3="$(OMNIPROBE_ROOT="$S3/does-not-exist" bash "$S3/tests/library_filter_chain/run_test.sh" 2>&1)"; RC3=$?
if [ "$RC3" -ne 0 ] && ! grep -q "Test 2 PASSED" <<<"$OUT3" && ! grep -q "SKIP" <<<"$OUT3"; then
  ac_pass "AC-3" "missing omniprobe tree fails loudly (rc=$RC3), no SKIP string"
else
  ac_fail "AC-3" "rc=$RC3; Test 2 PASSED present: $(grep -c 'Test 2 PASSED' <<<"$OUT3"); SKIP present: $(grep -c SKIP <<<"$OUT3")"
fi

# --- AC-4: uninstrumented static kernels cannot pass Test 2 ---
# The scratch root gets a build/ symlink so the line-155 gate lets Test 2 RUN.
# Without it, Test 2 is skipped and "no Test 2 PASSED" holds vacuously — the
# first draft of this check did exactly that, passing before the fix.
S4="$(new_scratch)"
ln -s "$REPO/build" "$S4/build"
OUT4="$(OMNIPROBE_ROOT="$REPO/build" bash "$S4/tests/library_filter_chain/run_test.sh" --no-instrument 2>&1)"; RC4=$?
if ! grep -q "Test 2 PASSED" <<<"$OUT4"; then
  ac_pass "AC-4" "with --no-instrument, Test 2 does not report PASSED (rc=$RC4)"
else
  ac_fail "AC-4" "Test 2 PASSED despite uninstrumented test libraries"
fi

rm -rf "$S1" "$S3" "$S4"

# --- AC-5: default full suite unchanged ---
SUITE="$(cd "$REPO" && bash tests/run_all_tests.sh 2>&1)"; RC5=$?
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
n() { strip <<<"$SUITE" | grep -E "^Suites $1:" | grep -oE '[0-9]+' | tail -1; }
RUN="$(n run)"; PASSED="$(n passed)"; SKIPPED="$(n skipped)"; FAILED="$(n failed)"
if [ "$RC5" -eq 0 ] && [ -n "$RUN" ] && [ "$RUN" = "$PASSED" ] && [ "${SKIPPED:-x}" = "0" ] && [ "${FAILED:-x}" = "0" ]; then
  ac_pass "AC-5" "full suite: $RUN run, $PASSED passed, 0 skipped, 0 failed"
else
  ac_fail "AC-5" "rc=$RC5 run=${RUN:-?} passed=${PASSED:-?} skipped=${SKIPPED:-?} failed=${FAILED:-?}"
fi

ac_check_write_scope "$AC_DOSSIER_PATH" "SCOPE"

ac_finish

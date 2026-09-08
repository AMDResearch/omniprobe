#!/usr/bin/env bash
#
# acceptance.sh — bf_hip-duplicate-code-object-load
#
# Promoted to active/ on 2026-09-08 with nothing yet implemented, so this script
# is still expected to FAIL. That is the correct state: the gate describes what
# "done" will mean, and it must not report success before the work exists.
#
#   bash .agents/workflows/active/bf_hip-duplicate-code-object-load/acceptance.sh
#
# Set AC_BUILD_DIR to the tree the defect reproduces in — the default `build/`
# is the gfx90a tree, and the bug has only been observed on gfx950:
#
#   AC_BUILD_DIR=$PWD/build_gfx950 bash .agents/workflows/active/.../acceptance.sh
#
# Several checks below are placeholders pinned to artefacts the workflow will
# create (the regression tests, the baselines). They are written as ac_fail with
# an explicit "not yet implemented" reason rather than being commented out, so
# that the tally always shows the real remaining distance.

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

AC_WORKFLOW_ID="bf_hip-duplicate-code-object-load"
AC_PACKET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AC_DOSSIER_PATH="$AC_PACKET_DIR/dossier.md"

# Where the workflow's build tree and evidence live. Override for a different
# architecture or build variant.
AC_BUILD_DIR="${AC_BUILD_DIR:-$AC_REPO_ROOT/build}"
AC_EVIDENCE_DIR="${AC_EVIDENCE_DIR:-$AC_REPO_ROOT/.untracked/bf_hip-dup-co}"
mkdir -p "$AC_EVIDENCE_DIR"

# ---------------------------------------------------------------------------
# AC-1: the build succeeds
# ---------------------------------------------------------------------------

if [ ! -d "$AC_BUILD_DIR" ]; then
  ac_fail "AC-1" "no build tree at $AC_BUILD_DIR — configure one, or set AC_BUILD_DIR"
elif cmake --build "$AC_BUILD_DIR" -j "$(nproc)" >"$AC_EVIDENCE_DIR/build.log" 2>&1; then
  ac_pass "AC-1" "cmake --build $AC_BUILD_DIR exited 0"
else
  ac_fail "AC-1" "cmake --build $AC_BUILD_DIR failed — see $AC_EVIDENCE_DIR/build.log"
fi

# ---------------------------------------------------------------------------
# AC-2 / AC-3: __constant__ survives instrumentation, with and without -k
# ---------------------------------------------------------------------------
#
# The reproducer is argprobe_g.hip, currently living outside this repo at
# pennant-amp-sidecar/.untracked/omniprobe-2026-09-01/argprobe_g.hip. Step 7 of
# the plan of record brings it in under tests/ as a regression test.

AC_CONST_TEST="$AC_REPO_ROOT/tests/test_constant_memory_visibility.sh"

if [ ! -f "$AC_CONST_TEST" ]; then
  ac_fail "AC-2" "regression test $AC_CONST_TEST does not exist yet (plan step 7)"
  ac_fail "AC-3" "regression test $AC_CONST_TEST does not exist yet (plan step 7)"
else
  if bash "$AC_CONST_TEST" --no-filter >"$AC_EVIDENCE_DIR/ac2.log" 2>&1; then
    ac_pass "AC-2" "__constant__ values correct inside instrumented clone, no -k argument"
  else
    ac_fail "AC-2" "__constant__ still corrupt without -k — see $AC_EVIDENCE_DIR/ac2.log"
  fi

  if bash "$AC_CONST_TEST" --with-matching-filter >"$AC_EVIDENCE_DIR/ac3.log" 2>&1; then
    ac_pass "AC-3" "__constant__ values correct when -k matches the kernel"
  else
    ac_fail "AC-3" "matching -k still selects a broken copy — see $AC_EVIDENCE_DIR/ac3.log"
  fi
fi

# ---------------------------------------------------------------------------
# AC-4: no suite regresses against the recorded pre-change baseline
# ---------------------------------------------------------------------------
#
# Measured at 74c6ed2 on 2026-09-08, before any change: 6 suites run, 1 passed,
# 4 SKIPPED for unset environment variables, 1 FAILED — "Handler tests", on
# `Expected pattern not found: 'memory heatmap report'`.
#
# So "the suite passes" is not achievable here and must not be the criterion; it
# would block this packet forever for a reason that has nothing to do with this
# bug. The criterion is instead: no suite that passed before fails after, and no
# suite that ran before is skipped after. A skipped suite is NOT a pass — the
# environment variables must be set for this gate to mean anything, and the
# check says so rather than counting a skip as success.

AC_SUITE_BASELINE="$AC_PACKET_DIR/baseline-run_all_tests.txt"

if [ ! -x "$AC_REPO_ROOT/tests/run_all_tests.sh" ]; then
  ac_fail "AC-4" "tests/run_all_tests.sh not found or not executable"
else
  bash "$AC_REPO_ROOT/tests/run_all_tests.sh" >"$AC_EVIDENCE_DIR/ac4.log" 2>&1
  ac4_skipped=$(sed -n 's/.*Suites skipped: *\([0-9]*\).*/\1/p' "$AC_EVIDENCE_DIR/ac4.log" | tail -1)
  ac4_failed=$(sed -n 's/.*Suites failed: *\([0-9]*\).*/\1/p' "$AC_EVIDENCE_DIR/ac4.log" | tail -1)
  ac4_skipped="${ac4_skipped:-unknown}"
  ac4_failed="${ac4_failed:-unknown}"

  if [ ! -f "$AC_SUITE_BASELINE" ]; then
    ac_fail "AC-4" "no suite baseline at $AC_SUITE_BASELINE — record one at HEAD before changing anything (plan step 2)"
  elif [ "$ac4_failed" = "unknown" ]; then
    ac_fail "AC-4" "could not parse a suite tally from $AC_EVIDENCE_DIR/ac4.log"
  elif [ "$ac4_skipped" != "0" ]; then
    ac_fail "AC-4" "$ac4_skipped suite(s) skipped — set INSTRUMENTED_ROCBLAS_LIB_DIR / TRITON_DIR etc; a skip is not a pass"
  elif [ "$ac4_failed" = "0" ]; then
    ac_pass "AC-4" "all suites ran and passed (baseline had 1 pre-existing failure: Handler tests)"
  else
    ac_fail "AC-4" "$ac4_failed suite(s) failed — compare against $AC_SUITE_BASELINE before concluding this is a regression"
  fi
fi

# ---------------------------------------------------------------------------
# AC-5: Triton is not regressed — the path coCache::addFile exists for
# ---------------------------------------------------------------------------
#
# `tests/triton/run_test.sh` exits 0 when TRITON_DIR is unset: it prints
# "SKIP: TRITON_DIR not set" and returns success. Measured 2026-09-08. Treating
# that exit code as a pass would report the single largest regression risk of
# this change as verified when nothing ran, so the skip is detected explicitly
# and reported as a FAIL.

if [ ! -f "$AC_REPO_ROOT/tests/triton/run_test.sh" ]; then
  ac_fail "AC-5" "tests/triton/run_test.sh not found — Triton coverage is the main regression risk of this change"
elif bash "$AC_REPO_ROOT/tests/triton/run_test.sh" >"$AC_EVIDENCE_DIR/ac5.log" 2>&1; then
  if grep -qE "SKIP:" "$AC_EVIDENCE_DIR/ac5.log"; then
    ac_fail "AC-5" "Triton tests SKIPPED (TRITON_DIR unset) — the script exits 0 on skip; this is not a pass"
  else
    ac_pass "AC-5" "Triton integration tests ran and passed"
  fi
else
  ac_fail "AC-5" "Triton integration tests failed — see $AC_EVIDENCE_DIR/ac5.log"
fi

# ---------------------------------------------------------------------------
# AC-6: no observable change on a workload that does not use __constant__
# ---------------------------------------------------------------------------
#
# WEAK by construction: agreeing with a baseline on one workload establishes no
# change on that workload, not absence of regression in general.

if [ ! -f "$AC_EVIDENCE_DIR/baseline-memanalysis.json" ]; then
  ac_fail "AC-6" "no pre-change baseline at $AC_EVIDENCE_DIR/baseline-memanalysis.json (plan step 2)"
elif [ ! -f "$AC_EVIDENCE_DIR/after-memanalysis.json" ]; then
  ac_fail "AC-6" "no post-change output at $AC_EVIDENCE_DIR/after-memanalysis.json"
elif diff -q "$AC_EVIDENCE_DIR/baseline-memanalysis.json" "$AC_EVIDENCE_DIR/after-memanalysis.json" >/dev/null 2>&1; then
  ac_weak "AC-6" "MemoryAnalysis output matches baseline on the sampled workload only"
else
  ac_fail "AC-6" "MemoryAnalysis output differs from baseline — see diff of $AC_EVIDENCE_DIR/*-memanalysis.json"
fi

# ---------------------------------------------------------------------------
# AC-7: -k restricts dispatch, per its documented meaning
# ---------------------------------------------------------------------------

AC_FILTER_TEST="$AC_REPO_ROOT/tests/test_kernel_filter_semantics.sh"
if [ ! -f "$AC_FILTER_TEST" ]; then
  ac_fail "AC-7" "filter-semantics test $AC_FILTER_TEST does not exist yet (plan step 7)"
elif bash "$AC_FILTER_TEST" >"$AC_EVIDENCE_DIR/ac7.log" 2>&1; then
  ac_pass "AC-7" "-k instruments matching kernels and leaves non-matching kernels on their originals"
else
  ac_fail "AC-7" "-k semantics still inverted or partial — see $AC_EVIDENCE_DIR/ac7.log"
fi

# ---------------------------------------------------------------------------
# AC-8: a filtered run still gets DWARF correlation (no sacrificial kernel)
# ---------------------------------------------------------------------------

if [ ! -f "$AC_FILTER_TEST" ]; then
  ac_fail "AC-8" "no test yet asserting DWARF line attribution under a filter (plan step 7)"
elif bash "$AC_FILTER_TEST" --assert-dwarf >"$AC_EVIDENCE_DIR/ac8.log" 2>&1; then
  ac_pass "AC-8" "filtered run reports non-zero source-line attribution; no sacrificial kernel needed"
else
  ac_fail "AC-8" "filtered run still lacks DWARF correlation — see $AC_EVIDENCE_DIR/ac8.log"
fi

# ---------------------------------------------------------------------------
# AC-9: the duplicate load is avoided, not merely bypassed
# ---------------------------------------------------------------------------
#
# Amended 2026-09-08 with user approval. The previous check compared `Adding`
# counts before and after, and the fix renames that caller-side line from
# `Adding` to `Indexing` for files it no longer privately loads — so the count
# would have dropped for a rename alone, with no behaviour change. A check that
# something unrelated can satisfy is not a check.
#
# `Loading private code object` is emitted inside coCache::addFile at the point
# an HSA executable is actually created. It cannot be produced without the load
# happening, and it cannot be suppressed while the load still happens.
#
# Both conditions are required. Zero private loads alone would also be true of a
# run that processed no files at all, so the indexed count guards against the
# work having been skipped rather than avoided.

AC_AFTER_LOG="$AC_EVIDENCE_DIR/adding-after.log"

if [ ! -f "$AC_AFTER_LOG" ]; then
  ac_fail "AC-9" "missing $AC_AFTER_LOG — capture a pure-HIP run under 'omniprobe -i'"
else
  # NOT `|| echo 0`: grep -c already prints 0 when it matches nothing, and it exits 1
  # while doing so, so the fallback appends a second line and the variable becomes
  # "0\n0" — which is neither -eq nor -ne 0 and silently derails every branch below.
  # The check this one replaces had the same idiom, and it would have misfired the
  # moment the count it was watching reached zero, which is exactly when it mattered.
  private_loads=$(grep -c "^Loading private code object " "$AC_AFTER_LOG" 2>/dev/null || true)
  indexed=$(grep -c "^Indexing " "$AC_AFTER_LOG" 2>/dev/null || true)
  if [ "$private_loads" -ne 0 ]; then
    ac_fail "AC-9" "$private_loads code object(s) still loaded into a private executable on a pure-HIP workload (see $AC_AFTER_LOG)"
  elif [ "$indexed" -eq 0 ]; then
    ac_fail "AC-9" "no files were indexed — the run processed nothing, so zero private loads proves nothing (see $AC_AFTER_LOG)"
  elif [ "$private_loads" -eq 0 ]; then
    ac_pass "AC-9" "$indexed code objects indexed, 0 loaded into a private executable"
  else
    ac_fail "AC-9" "$private_loads code object(s) still loaded into a private executable on a pure-HIP workload (see $AC_AFTER_LOG)"
  fi
fi

# ---------------------------------------------------------------------------
# Out-of-scope writes
# ---------------------------------------------------------------------------

ac_check_write_scope "$AC_DOSSIER_PATH" "SCOPE"

# ---------------------------------------------------------------------------

ac_finish

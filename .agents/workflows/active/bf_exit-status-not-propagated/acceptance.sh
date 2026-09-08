#!/usr/bin/env bash
#
# acceptance.sh — bf_exit-status-not-propagated
#
#   bash .agents/workflows/<state>/bf_exit-status-not-propagated/acceptance.sh
#
# Two deliberate choices:
#
#  1. AC-1..AC-3 assert EXACT exit numbers, never "nonzero". A fix that always
#     exits 1 satisfies "nonzero" while being a different bug wearing this one's
#     clothes, and AC-3 is what stops it.
#  2. AC-7 does not grep run_all_tests.sh. That grep is a proven vacuous PASS —
#     a pattern built from the test's own path components matches the untouched
#     file ("tests" hits run_handler_tests.sh; "run_test.sh" appears five times).
#     Verified 2026-09-08. The suite banner from a real run cannot be faked by a
#     file that never runs.
#
# This packet needs no GPU: the targets are /bin/sh stubs. Keep it that way.

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

AC_WORKFLOW_ID="bf_exit-status-not-propagated"
AC_PACKET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AC_DOSSIER_PATH="$AC_PACKET_DIR/dossier.md"

# ---------------------------------------------------------------------------
# Locate omniprobe
# ---------------------------------------------------------------------------

OP="${OMNIPROBE:-$AC_REPO_ROOT/build/bin/omniprobe}"
[ -x "$OP" ] || OP="$AC_REPO_ROOT/install/omniprobe/bin/omniprobe"
OP_OK=0
[ -x "$OP" ] && OP_OK=1

ANALYZER="${AC_ANALYZER:-MemoryAnalysis}"

# Run omniprobe over a stub target and echo its exit status.
op_status() {
  "$OP" -i -a "$ANALYZER" -- /bin/sh -c "$1" >/dev/null 2>&1
  echo $?
}

# --- AC-1: a specific nonzero status is propagated verbatim ---
if [ "$OP_OK" != 1 ]; then
  ac_fail "AC-1" "omniprobe not found at $OP — build it, or set OMNIPROBE"
else
  RC="$(op_status 'exit 42')"
  if [ "$RC" = "42" ]; then
    ac_pass "AC-1" "target exiting 42 is reported as 42"
  else
    ac_fail "AC-1" "target exited 42 but omniprobe reported $RC (expected exactly 42, not merely nonzero)"
  fi
fi

# --- AC-2: a signal death is reported recognisably (128 + 11) ---
if [ "$OP_OK" != 1 ]; then
  ac_fail "AC-2" "omniprobe not found — cannot check signal propagation"
else
  RC="$(op_status 'kill -SEGV $$')"
  if [ "$RC" = "139" ]; then
    ac_pass "AC-2" "target killed by SIGSEGV is reported as 139"
  elif [ "$RC" = "0" ]; then
    ac_fail "AC-2" "target died of SIGSEGV and omniprobe reported 0 — this is the defect, unfixed"
  else
    ac_fail "AC-2" "target died of SIGSEGV; omniprobe reported $RC, expected 139 (128+11)"
  fi
fi

# --- AC-3: success still exits 0 (guards against "always exit 1") ---
if [ "$OP_OK" != 1 ]; then
  ac_fail "AC-3" "omniprobe not found — cannot check the success path"
else
  RC="$(op_status 'exit 0')"
  if [ "$RC" = "0" ]; then
    ac_pass "AC-3" "successful target still yields exit 0"
  else
    ac_fail "AC-3" "successful target yielded $RC — the fix reports failure where there is none"
  fi
fi

# --- AC-4: the API consumer raises rather than returning "[]" ---
# Behavioural: drive omniprobe/api/omniprobe.py itself. A source grep for
# "RuntimeError" would pass today, before any fix, since the raise already
# exists — it is the value it tests that is broken.
if [ "$OP_OK" != 1 ]; then
  ac_fail "AC-4" "omniprobe not found — cannot drive the API path"
elif [ ! -f "$AC_REPO_ROOT/omniprobe/api/omniprobe.py" ]; then
  ac_fail "AC-4" "omniprobe/api/omniprobe.py not found"
else
  # The API surface is a class: Omniprobe(...).analyze_memory(command), where
  # `command` is split on whitespace by _run. A quoted `sh -c '...'` therefore
  # cannot survive the split — the crashing target has to be a single token, so
  # it is a temp script.
  CRASHER="$(mktemp)"; printf '#!/bin/sh\nkill -SEGV $$\n' >"$CRASHER"; chmod +x "$CRASHER"
  API_OUT="$(mktemp)"
  AC_REPO_ROOT="$AC_REPO_ROOT" AC_OP="$OP" AC_CRASHER="$CRASHER" python3 - >"$API_OUT" 2>&1 <<'PY'
import os, sys, traceback
root = os.environ["AC_REPO_ROOT"]
sys.path.insert(0, os.path.join(root, "omniprobe"))
try:
    from api import Omniprobe
except Exception:
    print("IMPORT_FAILED"); traceback.print_exc(); sys.exit(0)
try:
    op = Omniprobe(os.environ["AC_OP"])
    res = op.analyze_memory(os.environ["AC_CRASHER"])
    print("RETURNED:", repr(res)[:300])
except RuntimeError as e:
    print("RAISED_RUNTIMEERROR:", str(e)[:200])
except Exception as e:
    print("RAISED_OTHER:", type(e).__name__, str(e)[:200])
PY
  rm -f "$CRASHER"
  if grep -q "RAISED_RUNTIMEERROR" "$API_OUT"; then
    ac_pass "AC-4" "API raises RuntimeError on a crashing target"
  elif grep -qE "RETURNED:.*(kernels=\[\]|^RETURNED: *'\[\]')" "$API_OUT"; then
    # kernels=[] specifically, not a bare [] anywhere in the repr — a rich result
    # object with a non-empty kernels list but an empty warnings list would match
    # the looser pattern and mislabel a different failure.
    ac_fail "AC-4" "API returned an empty result on a crashing target — the empty-but-well-formed failure this packet exists to stop"
  elif grep -qE "IMPORT_FAILED" "$API_OUT"; then
    ac_fail "AC-4" "could not import omniprobe.api (see output) — fix the probe to the real API surface rather than relaxing this criterion"
  else
    ac_fail "AC-4" "API did not raise RuntimeError on a crashing target: $(head -3 "$API_OUT" | tr '\n' ' ')"
  fi
  rm -f "$API_OUT"
fi

# --- AC-5: JSON output is still finalized on a failing run ---
if [ "$OP_OK" != 1 ]; then
  ac_fail "AC-5" "omniprobe not found — cannot check JSON finalization"
else
  JOUT="$(mktemp -u).json"
  CRASHER="$(mktemp)"; printf '#!/bin/sh\nkill -SEGV $$\n' >"$CRASHER"; chmod +x "$CRASHER"
  "$OP" -i -a "$ANALYZER" -t json -o "$JOUT" -- "$CRASHER" >/dev/null 2>&1
  if [ ! -f "$JOUT" ]; then
    ac_fail "AC-5" "no JSON output file produced on a failing run — finalization was skipped"
  elif python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$JOUT" 2>/dev/null; then
    ac_pass "AC-5" "JSON output on a failing run is present and parses"
  else
    ac_fail "AC-5" "JSON output on a failing run does not parse — the exit happens before finalization"
  fi
  rm -f "$JOUT" "$CRASHER"
fi

# --- AC-6: the second caller of capture_subprocess_output does not regress ---
#
# The observable here is deliberately NOT "a gfx string appears in the env dump".
# get_local_isa() is only consulted on the Triton path, its arch list stops at
# gfx942 (so it returns None on this node's gfx90a-and-later hardware in some
# configurations), and a HIP run never prints it — so that check false-FAILs for
# reasons unrelated to this packet. Verified 2026-09-08: `-e` on a HIP run emits
# LOGDUR_* only, no architecture.
#
# The actual regression risk is precise: if the fix calls sys.exit() *inside*
# capture_subprocess_output rather than returning a status, the rocminfo call at
# omniprobe/omniprobe:225 would terminate the interpreter during ISA detection.
# So drive that exact shape — a failing command through the handler= / new_env=
# call form — and require the interpreter to survive it.
if [ ! -f "$AC_REPO_ROOT/omniprobe/omniprobe" ]; then
  ac_fail "AC-6" "omniprobe/omniprobe not found"
else
  ISA_OUT="$(mktemp)"
  AC_REPO_ROOT="$AC_REPO_ROOT" python3 - >"$ISA_OUT" 2>&1 <<'PY'
import importlib.util, os, sys, traceback
root = os.environ["AC_REPO_ROOT"]
spec = importlib.util.spec_from_loader(
    "op_cli", importlib.machinery.SourceFileLoader("op_cli", os.path.join(root, "omniprobe", "omniprobe")))
try:
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
except Exception:
    print("IMPORT_FAILED"); traceback.print_exc(); sys.exit(0)
seen = []
def handler(stream, mask):
    seen.append(stream.readline())
try:
    # A command that FAILS, driven through the second caller's call shape.
    m.capture_subprocess_output(["/bin/sh", "-c", "echo probe-line; exit 3"],
                                handler=handler, new_env=None)
except SystemExit as e:
    print("INTERPRETER_EXITED:", e.code); sys.exit(0)
except Exception as e:
    print("RAISED:", type(e).__name__, str(e)[:120]); sys.exit(0)
print("SURVIVED, lines=%d" % len(seen))
PY
  if grep -q "^SURVIVED" "$ISA_OUT"; then
    ac_pass "AC-6" "capture_subprocess_output returns on a failing command instead of exiting — the rocminfo caller is safe"
  elif grep -q "INTERPRETER_EXITED" "$ISA_OUT"; then
    ac_fail "AC-6" "capture_subprocess_output terminated the interpreter on a failing command — this breaks ISA detection at omniprobe/omniprobe:225"
  else
    ac_fail "AC-6" "could not exercise capture_subprocess_output: $(head -2 "$ISA_OUT" | tr '\n' ' ')"
  fi
  rm -f "$ISA_OUT"
fi

# --- AC-7 / AC-8: the full suite. Skipped as FAIL while the test is absent. ---
# Running the whole suite is expensive and needs .untracked/test-env.sh sourced
# on gfx90a hardware for the instrumented-library suites not to skip. There is
# no point paying that before the new test exists; reporting FAIL (never PASS)
# keeps the skip honest.
if [ ! -f "$AC_REPO_ROOT/tests/test_exit_status.sh" ]; then
  ac_fail "AC-7" "tests/test_exit_status.sh does not exist — full suite not run"
  ac_fail "AC-8" "prerequisites absent — full suite not run"
else
  SUITE_OUT="$(mktemp)"
  bash "$AC_REPO_ROOT/tests/run_all_tests.sh" >"$SUITE_OUT" 2>&1
  SUITE_RC=$?
  if grep -qiE '^.*Suite [0-9]+:.*exit status' "$SUITE_OUT"; then
    ac_pass "AC-7" "the new suite is registered and actually ran inside run_all_tests.sh"
  else
    ac_fail "AC-7" "no 'Suite N: ...exit status...' banner in the run_all_tests.sh output — the new test is not registered, or did not run"
  fi
  if [ "$SUITE_RC" -eq 0 ] && grep -qiE 'Suites skipped:[[:space:]]*0([^0-9]|$)' "$SUITE_OUT"; then
    ac_pass "AC-8" "run_all_tests.sh: exit 0, 0 failed, 0 skipped"
  else
    ac_fail "AC-8" "run_all_tests.sh did not report exit 0 with 0 failed and 0 skipped (rc=$SUITE_RC); see $SUITE_OUT"
  fi
fi

ac_check_write_scope "$AC_DOSSIER_PATH" "SCOPE"

ac_finish

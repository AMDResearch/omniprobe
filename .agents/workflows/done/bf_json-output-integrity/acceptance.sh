#!/usr/bin/env bash
#
# acceptance.sh — bf_json-output-integrity
#
#   bash .agents/workflows/<state>/bf_json-output-integrity/acceptance.sh
#
# Needs a GPU node with an arch-matched build in <repo>/build. AC-1..AC-4 are
# the checks of tests/test_json_output.sh (mapping in the dossier); this script
# requires every one of them to have run and passed. On the unfixed build 9 of
# 14 fail (artifacts.md). AC-5 (full suite) is run separately.

set -u -o pipefail
root="$(git rev-parse --show-toplevel)"
[ -f "$root/.untracked/test-env.sh" ] && source "$root/.untracked/test-env.sh" >/dev/null 2>&1
export ROCR_VISIBLE_DEVICES="${ROCR_VISIBLE_DEVICES:-0}"
export LD_LIBRARY_PATH="$root/build:${LD_LIBRARY_PATH:-}"

out="$("$root/tests/test_json_output.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
pass="$(printf '%s\n' "$out" | grep -c '✓ PASS')"
fail="$(printf '%s\n' "$out" | grep -c '✗ FAIL')"
printf '%s\n' "$out" | grep -E '^\[TEST|PASS|FAIL'
if [ "$pass" -eq 14 ] && [ "$fail" -eq 0 ]; then
  echo "PASS  AC-1..4  14/14 output-integrity checks pass"
  exit 0
fi
echo "FAIL  AC-1..4  $pass passed, $fail failed (want 14, 0)"
exit 1

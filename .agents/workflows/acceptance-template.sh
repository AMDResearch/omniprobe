#!/usr/bin/env bash
#
# acceptance.sh — the executable form of a workflow's acceptance criteria.
#
# Copy this file into a packet directory as `acceptance.sh`, then replace every
# TODO. One call per acceptance criterion, in the dossier's order, using the
# verdict that honestly describes what the check establishes.
#
#   bash .agents/workflows/<state>/<workflow-id>/acceptance.sh
#
# Exit 0 is the only evidence that the workflow may stop. `stop-acceptance.sh`
# runs this script as a Stop hook and refuses to let an agent finish until it
# does — so an unedited copy must fail, and this one does.
#
# The four verdicts, and how to choose:
#
#   ac_pass   The check establishes the property. Prefer this; if you can make a
#             criterion cleanly checkable by rewording it, do that instead of
#             settling for a weaker verdict.
#   ac_weak   The check is indirect — usually text presence. It can pass on
#             input that lacks the property: a grep for "target repo" matches a
#             document saying "do NOT treat the target repo as the codebase".
#             Non-gating. Never launder one of these into an ac_pass.
#   ac_judge  Not mechanically checkable at all, typically a claim about how an
#             agent behaves after reading a document. Non-gating; a human
#             decides. The dossier must mark the criterion `[judgement]` and
#             state why, and the third argument here is that reason.
#   ac_fail   The property does not hold. The only verdict that gates the exit
#             code.
#
# Expect roughly a fifth of a real dossier's criteria to land outside ac_pass.
# That ratio is a property of this kind of work, not a defect in the dossier.
#
# Environment:
#   AMP_AC_LIB        path to acceptance-lib.sh. Defaults to the installed
#                     location; override only for testing.
#   AMP_AC_VALIDATOR  see acceptance-lib.sh. Opt-in judgement engine.

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

# ---------------------------------------------------------------------------
# Which workflow this is
# ---------------------------------------------------------------------------
#
# Both are read by the AMP_AC_VALIDATOR seam when it is enabled, and the dossier
# path is what ac_check_write_scope parses the declared write scope from.
#
# The dossier is found as a sibling of this script rather than under a hardcoded
# `active/`, because a packet's lifecycle directory changes when it is promoted
# or completed. Hardcoding the state leaves every archived packet with a script
# that reports FAIL on a dossier it can no longer find — which reads exactly like
# a real regression, and destroys the one thing an archived gate is for: being
# re-runnable later to check what "done" actually meant.

AC_WORKFLOW_ID="TODO-workflow-id"
AC_PACKET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AC_DOSSIER_PATH="$AC_PACKET_DIR/dossier.md"

# ---------------------------------------------------------------------------
# Criteria
# ---------------------------------------------------------------------------
#
# Delete this line once at least one real criterion is checked below. It exists
# so that an unedited copy of this template fails loudly rather than reporting
# an empty success, which would be worse than having no acceptance script.

ac_fail TODO "this acceptance script is still the unedited template — replace the example checks below with the dossier's real criteria"

# --- AC-1: a clean, direct check. This is the shape to aim for. ---
if [ -f "$AC_REPO_ROOT/.agents/project.json" ]; then
  ac_pass "AC-1" "project.json exists"
else
  ac_fail "AC-1" "project.json is missing"
fi

# --- AC-2: a text-presence check, which is weaker than it looks. ---
# The grep proves the words are in the file, not that the file means them, so
# this reports WEAK even when it succeeds.
if grep -qi "stop conditions" "$AC_REPO_ROOT/.agents/policy/guardrails.md" 2>/dev/null; then
  ac_weak "AC-2" "guardrails.md mentions stop conditions (text presence only)"
else
  ac_fail "AC-2" "guardrails.md does not mention stop conditions"
fi

# --- AC-3: not checkable by a script. Report it and move on. ---
# The third argument is the reason, and it must match the `[judgement]` reason
# in the dossier. A human reviewer — or a validator, if AMP_AC_VALIDATOR is
# set — resolves it. It never gates the exit code.
ac_judge "AC-3" "the skill instructs the agent to record a reason for every judgement criterion" \
  "this is a claim about how an agent behaves after reading a SKILL.md; the file-level check that the instruction is present is separate and mechanical"

# --- Out-of-scope writes (DEC-7: detection, not prevention). ---
# Parses the ```write-scope block from the dossier and fails naming anything the
# working tree has touched outside it. Framework-owned paths are allowlisted by
# the library. A dossier with no write-scope block falls back to the prose
# metadata line and reports WEAK.
ac_check_write_scope "$AC_DOSSIER_PATH" "SCOPE"

# --- The test suite. Uncomment for any project that has one. ---
# PASS only when the run exits 0, collected == passed, and nothing was skipped.
# There is deliberately no pinned test count: a hand-maintained baseline goes
# stale silently and stops catching the delete-the-failing-test loophole it was
# added for, while collected == passed catches the same thing and never needs
# updating. Pass pytest arguments after the id; the default is `tests/`.
#
# ac_check_pytest_clean "TESTS"
#
# For a project that is not Python, replace it with the equivalent for your
# build — the requirement is the same: the command exits 0, and nothing was
# quietly skipped.

# ---------------------------------------------------------------------------
# Summary and exit code
# ---------------------------------------------------------------------------
#
# Prints the tally and exits 0 if and only if no FAIL was emitted. WEAK and
# JUDGE are reported but never gate: a weak check is still a check, and a
# judgement criterion is a human's call. Must be the last line.

ac_finish

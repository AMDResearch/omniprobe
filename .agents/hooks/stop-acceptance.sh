#!/usr/bin/env bash
#
# stop-acceptance.sh — a {"type":"command"} Stop hook that refuses to let an
# agent stop until the active workflow's acceptance.sh exits 0.
#
# Register it per-invocation rather than committing it into a repository's
# .claude/settings.json, so it fires only for autonomous runs:
#
#   {"hooks":{"Stop":[{"matcher":"*","hooks":[
#     {"type":"command","command":"bash .agents/hooks/stop-acceptance.sh"}]}]}}
#
#   claude -p "<task>" --settings <that file> --permission-mode auto \
#          --max-budget-usd <cap>
#
# The last two flags are mandatory whenever this hook is active. Default
# permissions plus a blocking Stop hook plus no human present is a livelock: the
# agent cannot get approval to do the work, and the hook will not let it stop.
#
# Three invariants, each learned the hard way:
#
#   1. It consumes stdin. Claude Code hands the Stop event JSON on a pipe, and a
#      hook that never reads it leaves the writer blocked.
#   2. It exits 0 even when blocking. The decision lives in the JSON on stdout,
#      not in the exit code. A non-zero exit is a broken hook, not a refusal.
#   3. It terminates on its own. A blocking Stop hook has no iteration cap — a
#      spike observed eight consecutive firings, ended only by a budget ceiling.
#      Termination belongs here (no-progress detection), not in the budget,
#      which is a cost limit and cannot tell a livelock from slow progress.
#
# Environment:
#   AMP_ACCEPTANCE          path to the acceptance script to run. Overrides
#                           discovery. Useful for tests and for driving a packet
#                           that is not in active/.
#   AMP_AC_REPO_ROOT        framework root — the directory holding .agents/.
#                           Defaults to the git toplevel, then to this script's
#                           own location when the toplevel has no .agents/.
#   AMP_ACCEPTANCE_TIMEOUT  seconds before a single acceptance script is killed.
#                           Default 900. Requires timeout(1); ignored without it.

# No `set -e`: every exit path here must print a JSON decision, and a bare
# non-zero return from a check would skip it and look like a broken hook.
set -u -o pipefail

# Longest block reason we will send back. The full output still goes to the
# state file and is what no-progress detection compares; only the message the
# agent receives is capped.
REASON_MAX_LINES=200
REASON_MAX_CHARS=12000

# ---------------------------------------------------------------------------
# 1. Drain stdin (invariant 1)
# ---------------------------------------------------------------------------

EVENT=""
if [ ! -t 0 ]; then
  EVENT="$(cat 2>/dev/null)" || EVENT=""
fi

# The event carries session_id, transcript_path, cwd, and stop_hook_active.
# Only session_id is used, to scope no-progress state to one run — see below.
# stop_hook_active is deliberately ignored: it was observed both true and false
# across firings and it did not prevent the eight-iteration runaway, so it is
# not a termination mechanism.
SESSION_ID="$(printf '%s' "$EVENT" \
  | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
SESSION_ID="${SESSION_ID:-}"

# ---------------------------------------------------------------------------
# 2. Where we are
# ---------------------------------------------------------------------------

if [ -n "${AMP_AC_REPO_ROOT:-}" ]; then
  REPO_ROOT="$AMP_AC_REPO_ROOT"
else
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT=""
  [ -z "$REPO_ROOT" ] && REPO_ROOT="$PWD"
fi

# Packets live under the framework root, which in a sidecar install is not the
# repository the agent is working in. When the cwd's toplevel has no .agents/,
# fall back to this script's own location: the hook is installed at
# <framework root>/.agents/hooks/stop-acceptance.sh, so three levels up is the
# root that owns it. Same reasoning as a packet's acceptance.sh resolving its
# dossier from ${BASH_SOURCE[0]} — the script knows where it lives, and the cwd
# does not.
#
# A pure fallback: it changes nothing when .agents/ is already present, which is
# every non-sidecar install and a sidecar the agent happens to be sitting in.
if [ ! -d "$REPO_ROOT/.agents" ]; then
  _self="${BASH_SOURCE[0]}"
  _self_root="$(cd "$(dirname "$_self")/../.." 2>/dev/null && pwd -P)"
  if [ -n "$_self_root" ] && [ -d "$_self_root/.agents" ]; then
    REPO_ROOT="$_self_root"
  fi
fi

STATE_DIR="$REPO_ROOT/.untracked/scratch"
STATE_FILE="$STATE_DIR/acceptance-last.txt"
STATE_SESSION="$STATE_DIR/acceptance-last-session.txt"

# amplify creates .untracked/scratch/, but it is gitignored and git does not
# track empty directories, so a fresh clone of an amplified repo does not have
# it. Create it rather than assume it.
mkdir -p "$STATE_DIR" 2>/dev/null

# ---------------------------------------------------------------------------
# 3. JSON emission
# ---------------------------------------------------------------------------

# Escape a string for a JSON string literal, in bash, with no python3
# dependency — a client repo need not be a Python project. Control characters
# other than tab, newline, and carriage return are dropped; acceptance output
# should not contain them, and JSON forbids them bare.
_json_escape() {
  local s
  s="$(printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037')"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# emit_approve [reason]
emit_approve() {
  if [ -n "${1:-}" ]; then
    printf '{"decision":"approve","reason":"%s"}\n' "$(_json_escape "$1")"
  else
    printf '{"decision":"approve"}\n'
  fi
  exit 0
}

# emit_block <reason>
emit_block() {
  printf '{"decision":"block","reason":"%s"}\n' "$(_json_escape "$1")"
  exit 0
}

# ---------------------------------------------------------------------------
# 4. Which script to run
# ---------------------------------------------------------------------------
#
# Resolution order:
#   1. $AMP_ACCEPTANCE, if set.
#   2. The single .agents/workflows/active/*/acceptance.sh, if exactly one.
#   3. None -> approve. An absent gate is not a failed gate: a packet that
#      predates the convention must behave exactly as it did before.
#   4. More than one -> run them all, block unless all pass.

SCRIPTS=()
RESOLUTION=""

if [ -n "${AMP_ACCEPTANCE:-}" ]; then
  RESOLUTION="AMP_ACCEPTANCE"
  SCRIPTS=("$AMP_ACCEPTANCE")
else
  shopt -s nullglob
  for candidate in "$REPO_ROOT"/.agents/workflows/active/*/acceptance.sh; do
    [ -f "$candidate" ] && SCRIPTS+=("$candidate")
  done
  shopt -u nullglob

  case "${#SCRIPTS[@]}" in
    0) RESOLUTION="none" ;;
    1) RESOLUTION="single" ;;
    *) RESOLUTION="multiple" ;;
  esac
fi

if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  emit_approve
fi

# ---------------------------------------------------------------------------
# 5. Run them
# ---------------------------------------------------------------------------

TIMEOUT_BIN="$(command -v timeout 2>/dev/null)" || TIMEOUT_BIN=""
AC_TIMEOUT="${AMP_ACCEPTANCE_TIMEOUT:-900}"

_run_script() {
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$AC_TIMEOUT" bash "$1" 2>&1
  else
    bash "$1" 2>&1
  fi
}

COMBINED=""
OVERALL_RC=0
MULTI=0
[ "${#SCRIPTS[@]}" -gt 1 ] && MULTI=1

for script in "${SCRIPTS[@]}"; do
  rel="${script#"$REPO_ROOT"/}"

  if [ ! -f "$script" ]; then
    # A misconfigured $AMP_ACCEPTANCE. Report it as failing output rather than
    # exiting non-zero, so that no-progress detection applies: an agent cannot
    # fix a bad environment variable, and without this it would be trapped.
    COMBINED="${COMBINED}FAIL  HOOK     acceptance script not found: $rel"$'\n'
    OVERALL_RC=1
    continue
  fi

  out="$(cd "$REPO_ROOT" && _run_script "$script")"
  rc=$?

  if [ "$rc" -eq 124 ] && [ -n "$TIMEOUT_BIN" ]; then
    out="${out}"$'\n'"FAIL  HOOK     acceptance script exceeded ${AC_TIMEOUT}s and was killed"
  fi

  if [ "$MULTI" -eq 1 ]; then
    COMBINED="${COMBINED}===> ${rel} (exit ${rc})"$'\n'"${out}"$'\n'
  else
    COMBINED="${out}"
  fi

  [ "$rc" -ne 0 ] && OVERALL_RC=1
done

# Normalize trailing newlines. The previous iteration's output is read back with
# $(cat ...), which strips them — so without stripping them here too, any output
# ending in a newline can never compare equal to itself and no-progress
# detection silently never fires. Command substitution applies exactly the same
# transformation, which is the point of writing it this way.
COMBINED="$(printf '%s' "$COMBINED")"

# ---------------------------------------------------------------------------
# 6. No-progress detection
# ---------------------------------------------------------------------------
#
# If this iteration's output is byte-identical to the previous one, nothing the
# agent did changed anything, and blocking again only spends money. Approve and
# say so: "unresolved" is an honest outcome and a visible one, unlike a silent
# livelock.
#
# State is scoped to the session. Without that, the first Stop of a *new*
# session would match the last failing output of the previous one and approve
# immediately — a free pass on the very first check.
#
# Known limitation: this compares bytes, so an acceptance script whose output
# includes a timestamp or an elapsed duration never matches itself and never
# terminates this way. ac_check_pytest_clean deliberately reports counts, not
# timings, for that reason.

PREV=""
PREV_VALID=0
if [ -f "$STATE_FILE" ]; then
  prev_session=""
  [ -f "$STATE_SESSION" ] && prev_session="$(cat "$STATE_SESSION" 2>/dev/null)"
  if [ "$prev_session" = "$SESSION_ID" ]; then
    PREV="$(cat "$STATE_FILE" 2>/dev/null)"
    PREV_VALID=1
  fi
fi

printf '%s' "$COMBINED" > "$STATE_FILE" 2>/dev/null
printf '%s' "$SESSION_ID" > "$STATE_SESSION" 2>/dev/null

# ---------------------------------------------------------------------------
# 7. Decide
# ---------------------------------------------------------------------------

if [ "$OVERALL_RC" -eq 0 ]; then
  emit_approve
fi

if [ "$PREV_VALID" -eq 1 ] && [ "$PREV" = "$COMBINED" ]; then
  emit_approve "unresolved: no progress since previous iteration"
fi

# Truncate from the front: the summary and the failing lines a script prints
# last are what the agent needs.
REASON="$COMBINED"
line_count="$(printf '%s\n' "$REASON" | wc -l)"
if [ "$line_count" -gt "$REASON_MAX_LINES" ]; then
  REASON="[earlier output truncated]"$'\n'"$(printf '%s' "$REASON" | tail -n "$REASON_MAX_LINES")"
fi
if [ "${#REASON}" -gt "$REASON_MAX_CHARS" ]; then
  REASON="[earlier output truncated]"$'\n'"${REASON: -$REASON_MAX_CHARS}"
fi

emit_block "Acceptance criteria are not met. The workflow's acceptance script exited non-zero.

$REASON

Fix the reported failures. Do not edit the acceptance script to make it pass, and do not weaken an acceptance criterion — record any proposed spec change in the packet's handoff.md instead."

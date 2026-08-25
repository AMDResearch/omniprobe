#!/usr/bin/env bash
#
# acceptance-lib.sh — shared verdict and check functions for a workflow's
# acceptance.sh.
#
# A workflow packet may contain an acceptance.sh that decides, mechanically,
# whether the workflow's acceptance criteria are met. That script sources this
# library, calls one verdict function per criterion, and ends with ac_finish.
# Exit 0 is the only signal that a workflow may stop; nothing else counts.
#
#   source "$(git rev-parse --show-toplevel)/.agents/hooks/acceptance-lib.sh"
#   [ -f README.md ] && ac_pass AC-1 "README exists" || ac_fail AC-1 "no README"
#   ac_finish
#
# Four verdicts, because two are not enough:
#
#   PASS  the property holds, and the check establishes it.
#   WEAK  the check is text-presence or otherwise indirect. It can pass on
#         input that does not have the property — a grep for "target repo"
#         matches a file saying "do NOT treat the target repo as ...".
#         Non-gating, but must never be printed as PASS.
#   JUDGE not mechanically checkable at all. Typically a claim about how an
#         agent behaves after reading a document. Non-gating; a human decides,
#         or a validator does (see AMP_AC_VALIDATOR below).
#   FAIL  the property does not hold. The only verdict that gates the exit code.
#
# The library is bash, not POSIX sh: it uses arrays and process substitution.
#
# Environment:
#   AMP_AC_VALIDATOR  path to an executable judgement engine. When set and
#                     executable, ac_finish pipes it the judgement criteria as
#                     JSON and applies the verdicts it returns. Unset by
#                     default; the gate stays deterministic and model-free.
#   AMP_AC_REPO_ROOT  framework root. Defaults to the git toplevel.

# Deliberately no `set -e`: a failing check must record a FAIL and continue, so
# that one run reports every unmet criterion rather than only the first.
set -u -o pipefail

# ---------------------------------------------------------------------------
# Roots
# ---------------------------------------------------------------------------
#
# Two roots, because a sidecar install is two repositories:
#
#   AC_FRAMEWORK_ROOT  the directory containing .agents/ — where the packets,
#                      the dossiers, and this library live.
#   AC_CODE_ROOT       where the work happens, and so where an out-of-scope
#                      write and the test suite both are.
#
# In a normal install they are the same directory and every check behaves
# exactly as it did when there was only one root. In a sidecar install they are
# siblings, and conflating them is a false PASS by construction: the scope check
# would inspect a repository containing only framework files and report clean no
# matter what the workflow did to the code.
#
# AC_REPO_ROOT survives as an alias of AC_FRAMEWORK_ROOT so that packet scripts
# written against the single-root library keep working.

if [ -n "${AMP_AC_REPO_ROOT:-}" ]; then
  AC_FRAMEWORK_ROOT="$AMP_AC_REPO_ROOT"
else
  AC_FRAMEWORK_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
AC_REPO_ROOT="$AC_FRAMEWORK_ROOT"

# Set when the install declares itself a sidecar but the target repository
# cannot be resolved. Never silently fall back to the framework root in that
# case — falling back is precisely the false PASS this exists to prevent, so the
# checks report it instead.
AC_ROOT_ERROR=""

# Resolved by reading .agents/project.json. Parsed with grep and sed rather than
# python3: the file is machine-written by amplify.py with a fixed shape, and a
# client repo need not be a Python project just to source this library.
_ac_resolve_code_root() {
  AC_CODE_ROOT="$AC_FRAMEWORK_ROOT"

  local pj="$AC_FRAMEWORK_ROOT/.agents/project.json"
  [ -f "$pj" ] || return 0
  grep -qE '"sidecar"[[:space:]]*:[[:space:]]*true' "$pj" 2>/dev/null || return 0

  local rel
  rel="$(sed -n 's/.*"target_repo"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pj" | head -1)"
  if [ -z "$rel" ]; then
    AC_ROOT_ERROR="project.json declares \"sidecar\": true but has no usable target_repo"
    return 0
  fi

  local candidate
  case "$rel" in
    /*) candidate="$rel" ;;
    *)  candidate="$AC_FRAMEWORK_ROOT/$rel" ;;
  esac

  local resolved
  resolved="$(cd "$candidate" 2>/dev/null && pwd -P)"
  if [ -z "$resolved" ]; then
    AC_ROOT_ERROR="sidecar target_repo does not resolve to a directory: $rel (from $AC_FRAMEWORK_ROOT)"
    return 0
  fi
  AC_CODE_ROOT="$resolved"
}
_ac_resolve_code_root

# True when the two roots are the same directory, which is the normal install
# and the path that must stay byte-identical to the single-root library.
_ac_single_root() {
  [ "$AC_CODE_ROOT" = "$AC_FRAMEWORK_ROOT" ]
}

# Guard for any check that reads a root. Emits one FAIL and returns 1 when the
# roots could not be resolved.
_ac_roots_ok() {
  [ -z "$AC_ROOT_ERROR" ] && return 0
  ac_fail "${1:-ROOTS}" "$AC_ROOT_ERROR"
  return 1
}

AC_PASS_COUNT=0
AC_WEAK_COUNT=0
AC_JUDGE_COUNT=0
AC_FAIL_COUNT=0

# Judgement criteria accumulated for the AMP_AC_VALIDATOR seam. Parallel
# arrays; bash 3.2 has no associative-array literals worth relying on.
AC_JUDGE_IDS=()
AC_JUDGE_TEXTS=()
AC_JUDGE_REASONS=()

# Framework-owned paths that no dossier declares but the framework writes to
# during any session. Without this, the out-of-scope check fails immediately on
# every run. Note that only packet directories under .agents/workflows/ are
# allowlisted — the templates that live directly in .agents/workflows/ are not,
# so editing dossier-template.md still has to be in a declared write scope.
#
# .agents/pm/, .agents/improvement/ and .agents/workflows/seeds/ are here for
# the same reason as .agents/state/: session-close runs pm-update
# unconditionally, so those writes are required, are nobody's deliverable, and
# cannot be cleared by the agent that triggers them.
#
# An entry here is *inert* for any path a dossier's write-scope block also
# names — see ac_check_write_scope. Declared beats allowlisted, so a packet
# whose deliverable is PM content is still checked against its own declaration
# rather than waved through by the allowlist.
AC_SCOPE_ALLOWLIST=(
  ".agents/state/"
  ".agents/pm/"
  ".agents/improvement/"
  ".agents/workflows/seeds/"
  ".untracked/"
  "__pycache__/"
  ".pytest_cache/"
)

# ---------------------------------------------------------------------------
# Packet lifecycle
# ---------------------------------------------------------------------------
#
# The lifecycle state of a packet is derived from its dossier's *path*, never
# from the dossier's `- Lifecycle State:` field. Measured across all 14 dossiers
# in the agentic_meta_project repository on 2026-08-17, the field disagrees with
# the directory in five of them — two suspended packets say `active`, one says
# `complete`, one `completed`, and one has no such field at all. The directory
# is ground truth; session-init's own reconciliation step says so in as many
# words. The field is retained as a cross-check and a disagreement is reported
# rather than silently resolved.
#
# Sets, for a dossier at .agents/workflows/<state>/<id>/dossier.md:
#   AC_LC_STATE  the lifecycle directory name
#   AC_LC_ID     the packet id (the dossier's parent directory name)
#
# Both are empty for a dossier at any other path — a test fixture, an ad-hoc
# location. That is not a failure: it means there is no packet here, so the
# rules that are about packets do not apply. Every stricter behaviour in this
# library keys off a non-empty AC_LC_STATE for exactly that reason.
AC_LC_STATE=""
AC_LC_ID=""

# The seven directories in .agents/workflows/ that are lifecycle states. Any
# other sibling — `seeds/`, and the templates that live directly in
# .agents/workflows/ — is deliberately not one.
_ac_is_lifecycle_dir() {
  case "$1" in
    draft|active|suspended|blocked|failed|done|abandoned) return 0 ;;
    *) return 1 ;;
  esac
}

# The three states in which a packet is finished and will not be worked again.
# The write-scope check stops evaluating in these; see ac_check_write_scope.
_ac_is_terminal_state() {
  case "$1" in
    done|abandoned|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# The three states in which a base-commit stamp is expected. `draft` is
# excluded because the stamp is written at promotion, so an unstamped draft is
# correct rather than deficient.
_ac_stamp_expected() {
  case "$1" in
    active|suspended|blocked) return 0 ;;
    *) return 1 ;;
  esac
}

# _ac_lifecycle_from_path <dossier-path>
#
# Matched on the path's own components rather than against a repository-relative
# prefix, so it works identically in a sidecar (where packets live in the
# framework root) and when a caller passes an absolute path.
_ac_lifecycle_from_path() {
  AC_LC_STATE=""
  AC_LC_ID=""

  local packet_dir state_dir workflows_dir agents_dir
  packet_dir="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 0
  [ -n "$packet_dir" ] || return 0

  state_dir="$(dirname "$packet_dir")"
  workflows_dir="$(dirname "$state_dir")"
  agents_dir="$(dirname "$workflows_dir")"

  [ "$(basename "$workflows_dir")" = "workflows" ] || return 0
  [ "$(basename "$agents_dir")" = ".agents" ] || return 0
  _ac_is_lifecycle_dir "$(basename "$state_dir")" || return 0

  AC_LC_STATE="$(basename "$state_dir")"
  AC_LC_ID="$(basename "$packet_dir")"
  return 0
}

# _ac_metadata_value <file> <label-ere>
#
# Reads the first `- Label: value` metadata line and prints its first
# whitespace-delimited token. The label is an ERE fragment, so a caller wanting
# a literal `(` must escape it.
#
# Note that a pattern for `Base Commit` does not also match `Base Commit
# (code)`: the pattern requires the colon to follow the label with only
# whitespace between, and ` (code):` is not whitespace.
_ac_metadata_value() {
  grep -m1 -E "^[[:space:]]*[-*][[:space:]]*$2[[:space:]]*:" "$1" 2>/dev/null \
    | sed -E "s/^[[:space:]]*[-*][[:space:]]*$2[[:space:]]*:[[:space:]]*//" \
    | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Verdicts
# ---------------------------------------------------------------------------

# ac_pass <id> <message>
ac_pass() {
  printf 'PASS  %-8s %s\n' "$1" "${2:-}"
  AC_PASS_COUNT=$((AC_PASS_COUNT + 1))
}

# ac_weak <id> <message>
# The check is indirect — text presence, shape, or a proxy for the real
# property. Reported distinctly from PASS on purpose; do not "upgrade" a weak
# check by calling ac_pass instead.
ac_weak() {
  printf 'WEAK  %-8s %s\n' "$1" "${2:-}"
  AC_WEAK_COUNT=$((AC_WEAK_COUNT + 1))
}

# ac_judge <id> <message> [reason]
# Not mechanically checkable. The reason states why, and is what a validator
# and a human reviewer both act on. Non-gating.
ac_judge() {
  printf 'JUDGE %-8s %s\n' "$1" "${2:-}"
  AC_JUDGE_COUNT=$((AC_JUDGE_COUNT + 1))
  AC_JUDGE_IDS+=("$1")
  AC_JUDGE_TEXTS+=("${2:-}")
  AC_JUDGE_REASONS+=("${3:-}")
}

# ac_fail <id> <message>
ac_fail() {
  printf 'FAIL  %-8s %s\n' "$1" "${2:-}"
  AC_FAIL_COUNT=$((AC_FAIL_COUNT + 1))
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

# ac_check_write_scope <dossier-path> [id]
#
# Compares the working tree against the dossier's declared write scope and
# fails naming every path outside it. Detection, not prevention: it reports
# what has already been written.
#
# Prefers a fenced ```write-scope block, one path per line. Falls back to the
# prose "- Intended Write Scope:" metadata line for dossiers written before the
# block existed — that parse is fragile, so it reports WEAK even when clean.
#
# Both roots are inspected. A path dirty in the code root is checked against the
# declared scope alone: the allowlist names framework-owned paths, and applying
# it to the code repository would excuse writes it was never meant to cover. A
# path dirty in the framework root is checked against the allowlist union the
# declared scope, as before. When the two roots coincide there is one scan and
# the result is identical to the single-root library's.
#
# One verdict line covers both roots rather than one line per root. Two lines
# would be more legible on a sidecar failure, but they would also change the
# criterion count of every packet that calls this once and reads the summary
# arithmetic — so legibility is bought with a root prefix on each reported path
# instead, and only when the roots actually differ.

# _ac_path_in_own_packet <path>
#
# The packet-directory carve-out. True when a write to this path needs no
# declaration.
#
# A packet may write anywhere inside **its own** directory without declaring it:
# run-log, handoff and artifacts are updated constantly and are nobody's
# deliverable. Writes to any **other** packet's directory are checked against
# the declared scope like any other path — before P1.2 they were not, so any
# workflow could rewrite any other workflow's dossier or acceptance script,
# including a completed one, and no gate reported it. Same shape as the
# laundering hole: the check silently passing work it should have caught.
#
# Unlike every other allowlisted region this carve-out was hardcoded rather than
# an AC_SCOPE_ALLOWLIST entry, so declared-beats-allowlisted could not reach it
# and declaring the path did not re-arm the check.
#
# Ownership is keyed on the packet **id**, not the full path, so moving a packet
# from active/ to done/ or suspended/ does not make its own files read as
# foreign — a completing packet writes its final run-log entry after the move.
#
# When the dossier is not itself inside a packet directory there is no "own
# packet" to privilege, and the blanket carve-out stands unchanged. That is the
# same principle as the stamp's lifecycle scoping and the unrecognized-path
# rule, applied a third time: the stricter rules apply only to things that are
# actually packets.
_ac_path_in_own_packet() {
  local rest="$1" pid
  case "$rest" in .agents/workflows/*) rest="${rest#.agents/workflows/}" ;; *) return 1 ;; esac
  # At least <state>/<id>/<something>: two more separators after workflows/.
  case "$rest" in */*/*) ;; *) return 1 ;; esac

  [ -z "$AC_LC_ID" ] && return 0

  rest="${rest#*/}"     # strip <state>/
  pid="${rest%%/*}"     # <id>
  [ "$pid" = "$AC_LC_ID" ]
}

# _ac_path_out_of_scope <path> <use-allowlist 0|1>
#
# Returns 0 when the path is outside everything that excuses it. The single
# decision point for both the dirty-tree scan and the commit-range scan, so the
# two cannot drift into disagreeing about what "out of scope" means.
_ac_path_out_of_scope() {
  local f="$1" use_allowlist="$2" a s allowed=0 in_scope=0

  if [ "$use_allowlist" -eq 1 ]; then
    if [ "${#_AC_ACTIVE_ALLOWLIST[@]}" -gt 0 ]; then
      for a in "${_AC_ACTIVE_ALLOWLIST[@]}"; do
        case "$f" in "$a"*|*"/$a"*) allowed=1; break ;; esac
      done
    fi
    [ "$allowed" -eq 0 ] && _ac_path_in_own_packet "$f" && allowed=1
    [ "$allowed" -eq 1 ] && return 1
  fi

  for s in "${_AC_SCOPE[@]}"; do
    case "$f" in "$s"*) in_scope=1; break ;; esac
  done
  [ "$in_scope" -eq 1 ] && return 1
  return 0
}

# Scan the commits a workflow has made since its base commit, appending
# offending paths to _AC_SCAN_OUT.
#
# This is the half of the check that `git status --porcelain` cannot do.
# Committing a file removes it from the dirty tree entirely, so a check that
# reads only the tree is closest to vacuous exactly when it is supposed to be
# decisive — and decays fastest for the agents following the checkpoint protocol
# most diligently.
#
# It enumerates commits (`git log --name-only`) rather than diffing
# `<base>..HEAD`. Measured in a scratch repository on 2026-08-17: a file created
# in one commit and deleted in a later one is reported by the enumeration and
# **not** by `git diff --name-only <base>..HEAD`, so a two-dot diff would
# reproduce the laundering hole this exists to close — commit the file, delete
# it, pass the check.
#
# Merge commits show no paths of their own here, which is correct: the commits
# they merge are themselves in the range and are enumerated individually. Only
# a change introduced *in* a merge commit would be missed, which the
# one-feature-branch assumption in this packet's dossier puts out of scope.
#
# _ac_scan_range <root> <base> <use-allowlist 0|1> <label>
_ac_scan_range() {
  local root="$1" base="$2" use_allowlist="$3" label="$4"
  local f

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    _ac_path_out_of_scope "$f" "$use_allowlist" \
      && _AC_SCAN_OUT="$_AC_SCAN_OUT ${label}${f}"
  done < <(git -C "$root" log --name-only --pretty=format: "$base..HEAD" 2>/dev/null | sort -u)
}

# _ac_resolve_stamp <root> <value>
#
# Echoes the resolved commit when the value names one in that repository.
# Silent and non-zero otherwise, which the caller reports as WEAK rather than
# FAIL: a fresh clone or a rewritten branch can legitimately lose the object,
# and an unclearable FAIL is a gate whose only escape is to stop gating.
_ac_resolve_stamp() {
  local root="$1" value="$2"
  git -C "$root" rev-parse --verify --quiet "${value}^{commit}" 2>/dev/null
}

# A stamp value that is not a hex object name at all — an unfilled
# `(unstamped — set at promotion)` placeholder, most often. Treated as absent
# rather than as unresolvable, because that is what it is.
_ac_stamp_is_placeholder() {
  case "$1" in
    "") return 0 ;;
    *[!0-9a-fA-F]*) return 0 ;;
    *) [ "${#1}" -lt 7 ] && return 0; return 1 ;;
  esac
}

# Scan one root's working tree, appending offending paths to _AC_SCAN_OUT.
#
# _ac_scan_root <root> <use-allowlist 0|1> <label>
_ac_scan_root() {
  local root="$1" use_allowlist="$2" label="$3"
  local line f

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    _AC_SCAN_DIRTY=1
    f="${line:3}"            # strip the two-column status and its separator
    f="${f%\"}"; f="${f#\"}" # git quotes paths containing special characters
    case "$f" in *' -> '*) f="${f##* -> }" ;; esac   # renames: judge the destination

    _ac_path_out_of_scope "$f" "$use_allowlist" \
      && _AC_SCAN_OUT="$_AC_SCAN_OUT ${label}${f}"
  done < <(git -C "$root" status --porcelain --untracked-files=all)
}

ac_check_write_scope() {
  local dossier="$1"
  local id="${2:-SCOPE}"
  local scope=() weak=0 line f

  _ac_roots_ok "$id" || return 1

  if [ ! -f "$dossier" ]; then
    ac_fail "$id" "dossier not found: $dossier"
    return 1
  fi

  # ---- Lifecycle -----------------------------------------------------------
  #
  # Derived from the path; the field only ever contradicts it, never decides.
  _ac_lifecycle_from_path "$dossier"

  local field_state note=""
  field_state="$(_ac_metadata_value "$dossier" "Lifecycle State" | tr '[:upper:]' '[:lower:]')"
  if [ -n "$AC_LC_STATE" ] && [ -n "$field_state" ] && [ "$field_state" != "$AC_LC_STATE" ]; then
    note=" [the dossier's Lifecycle State field says '$field_state'; the directory says '$AC_LC_STATE' and the directory decides]"
  fi

  # An archived packet's declared scope stopped describing anything the moment
  # it completed. Every *other* check in an archived gate still means something
  # — which is what makes an old gate a usable regression suite over past
  # deliverables — so this is scoped to the one verdict line and the rest of the
  # script runs untouched.
  #
  # Component A makes this necessary rather than merely tidy: base..HEAD grows
  # forever for a completed packet, so without this the check would get
  # monotonically wronger with every unrelated commit.
  if [ -n "$AC_LC_STATE" ] && _ac_is_terminal_state "$AC_LC_STATE"; then
    ac_weak "$id" "not evaluated because the packet is archived in $AC_LC_STATE/$note"
    return 0
  fi

  # Fenced block: lines between ```write-scope and the next ```.
  #
  # Both comment forms are stripped: a whole-line `#` and a trailing ` # ...`.
  # The trailing form is the one the dossier template documents for a dated
  # scope amendment — "path   # amended <date> — <reason>" — and it used to be
  # kept as part of the path, so a *declared* entry silently matched nothing and
  # every write to it reported out of scope. Found 2026-08-21 by
  # rf_client-knowledge-integrity, when the first real amendment wrote to a path
  # that had carried such a comment since the day it was declared; the entry had
  # been inert the whole time and nothing said so, because the packet had not
  # yet written to that file.
  #
  # The pattern requires whitespace before the `#`, so a path that legitimately
  # contains one is untouched. A scope entry is a single path and cannot contain
  # a space, which is what makes that discrimination safe.
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    case "$line" in \#*) continue ;; esac
    line="${line%%[[:space:]]#*}"             # strip a trailing " # comment"
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    [ -z "$line" ] && continue
    scope+=("$line")
  done < <(awk '/^[[:space:]]*```write-scope[[:space:]]*$/{f=1; next} f && /^[[:space:]]*```/{exit} f' "$dossier")

  if [ "${#scope[@]}" -eq 0 ]; then
    # Prose fallback: "- Intended Write Scope: a, b, c"
    weak=1
    local prose
    prose="$(grep -m1 -E '^[[:space:]]*[-*][[:space:]]*Intended Write Scope[[:space:]]*:' "$dossier" 2>/dev/null \
             | sed -E 's/^[[:space:]]*[-*][[:space:]]*Intended Write Scope[[:space:]]*:[[:space:]]*//')"
    if [ -n "$prose" ]; then
      local IFS=','
      for f in $prose; do
        f="${f#"${f%%[![:space:]]*}"}"
        f="${f%"${f##*[![:space:]]}"}"
        f="${f%\`}"; f="${f#\`}"
        [ -n "$f" ] && scope+=("$f")
      done
    fi
  fi

  if [ "${#scope[@]}" -eq 0 ]; then
    ac_fail "$id" "no write scope declared in $dossier (no write-scope block, no Intended Write Scope line)"
    return 1
  fi

  # Declared beats allowlisted. An allowlist entry is inert when the dossier
  # declares a path under it, or declares a path it sits under — either way the
  # packet has claimed that region, so its writes there are checked against the
  # declaration rather than excused. Computed once, before scanning.
  _AC_ACTIVE_ALLOWLIST=()
  local a s is_inert
  for a in "${AC_SCOPE_ALLOWLIST[@]}"; do
    is_inert=0
    for s in "${scope[@]}"; do
      case "$s" in "$a"*) is_inert=1; break ;; esac
      case "$a" in "$s"*) is_inert=1; break ;; esac
    done
    [ "$is_inert" -eq 0 ] && _AC_ACTIVE_ALLOWLIST+=("$a")
  done

  # --untracked-files=all matters: by default git collapses an untracked
  # directory into a single "dir/" entry, which matches neither an allowlist
  # entry nor a scope entry, so a wholly-allowlisted new directory would report
  # as out of scope.
  _AC_SCOPE=("${scope[@]}")
  _AC_SCAN_DIRTY=0
  _AC_SCAN_OUT=""

  # ---- Base commits --------------------------------------------------------
  #
  # One stamp per repository. In a sidecar the two roots are two independent
  # histories, so the framework root's `Base Commit` says nothing about the code
  # root and a `Base Commit (code)` line carries that one. In a single-root
  # install the plain line covers the one repository and the (code) line is
  # neither required nor read.
  local stamp_note="" ranged=0 range_desc="" missing=()
  local base_fw="" base_code="" resolved=""

  if [ -n "$AC_LC_STATE" ] && _ac_stamp_expected "$AC_LC_STATE"; then
    base_fw="$(_ac_metadata_value "$dossier" "Base Commit")"
    if _ac_stamp_is_placeholder "$base_fw"; then
      missing+=("no '- Base Commit:' stamp")
    elif resolved="$(_ac_resolve_stamp "$AC_FRAMEWORK_ROOT" "$base_fw")"; then
      _ac_single_root && range_desc="commits since ${base_fw}" \
                      || range_desc="framework commits since ${base_fw}"
      ranged=1
    else
      missing+=("Base Commit '$base_fw' does not resolve to a commit")
    fi

    if ! _ac_single_root; then
      base_code="$(_ac_metadata_value "$dossier" "Base Commit \(code\)")"
      if _ac_stamp_is_placeholder "$base_code"; then
        missing+=("no '- Base Commit (code):' stamp for the code root")
      elif resolved="$(_ac_resolve_stamp "$AC_CODE_ROOT" "$base_code")"; then
        range_desc="${range_desc:+$range_desc, }code commits since ${base_code}"
        ranged=1
      else
        missing+=("Base Commit (code) '$base_code' does not resolve in the code root")
      fi
    fi

    local m
    for m in ${missing[@]+"${missing[@]}"}; do
      stamp_note="${stamp_note:+$stamp_note; }$m"
    done
  fi

  if _ac_single_root; then
    _ac_scan_root "$AC_FRAMEWORK_ROOT" 1 ""
    [ -n "$base_fw" ] && _ac_resolve_stamp "$AC_FRAMEWORK_ROOT" "$base_fw" >/dev/null 2>&1 \
      && _ac_scan_range "$AC_FRAMEWORK_ROOT" "$base_fw" 1 ""
  else
    # Code root first: an out-of-scope write to the project under test is the
    # finding that matters, and it should lead the report.
    _ac_scan_root "$AC_CODE_ROOT" 0 "code:"
    [ -n "$base_code" ] && _ac_resolve_stamp "$AC_CODE_ROOT" "$base_code" >/dev/null 2>&1 \
      && _ac_scan_range "$AC_CODE_ROOT" "$base_code" 0 "code:"
    _ac_scan_root "$AC_FRAMEWORK_ROOT" 1 "framework:"
    [ -n "$base_fw" ] && _ac_resolve_stamp "$AC_FRAMEWORK_ROOT" "$base_fw" >/dev/null 2>&1 \
      && _ac_scan_range "$AC_FRAMEWORK_ROOT" "$base_fw" 1 "framework:"
  fi

  local dirty="$_AC_SCAN_DIRTY"
  local out_of_scope="$_AC_SCAN_OUT"

  if [ -n "$out_of_scope" ]; then
    ac_fail "$id" "writes outside declared scope:$out_of_scope$note"
    return 1
  fi

  # A missing or unresolvable stamp is WEAK and never PASS. The scan that did
  # run is real and is reported, but a packet whose committed writes were never
  # compared against anything must not be indistinguishable from one whose
  # were. Reported after the FAIL branch above, because an out-of-scope write is
  # the finding that matters and one verdict line covers the criterion.
  if [ -n "$stamp_note" ]; then
    ac_weak "$id" "$stamp_note — the working tree was scanned and is clean, but committed work was not$note"
    return 0
  fi

  if [ "$weak" -eq 1 ]; then
    ac_weak "$id" "no write-scope block; parsed the prose Intended Write Scope line (${#scope[@]} entries) — no out-of-scope writes found$note"
  elif [ "$dirty" -eq 0 ] && [ "$ranged" -eq 0 ]; then
    ac_pass "$id" "no out-of-scope writes (working tree clean)$note"
  elif [ "$ranged" -eq 1 ]; then
    ac_pass "$id" "no writes outside the declared write scope (${#scope[@]} entries; working tree and $range_desc)$note"
  else
    ac_pass "$id" "no writes outside the declared write scope (${#scope[@]} entries)$note"
  fi
  return 0
}

# ac_check_pytest_clean [id] [pytest-args...]
#
# PASS only when the suite exits 0, every collected test passed, and nothing
# was skipped. No pinned baseline: a count pinned by hand goes stale silently
# and stops catching the delete-the-failing-test loophole it existed for.
# collected == passed catches deletion just as well and never needs updating.
#
# Runs in AC_CODE_ROOT. In a sidecar install the framework root holds no tests
# at all, so running there would collect nothing — which the "collected no
# tests" branch below would report, but as a puzzling failure rather than the
# suite result the criterion asks for.
ac_check_pytest_clean() {
  local id="${1:-PYTEST}"
  shift || true
  local args=("$@")
  [ "${#args[@]}" -eq 0 ] && args=("tests/")

  _ac_roots_ok "$id" || return 1

  local log rc out
  log="$(mktemp)"
  ( cd "$AC_CODE_ROOT" && python3 -m pytest "${args[@]}" -q ) > "$log" 2>&1
  rc=$?
  out="$(cat "$log")"
  rm -f "$log"

  local n_pass n_fail n_skip n_err n_collect
  n_pass="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed'   | grep -oE '^[0-9]+' | tail -1)"
  n_fail="$(printf '%s\n' "$out" | grep -oE '[0-9]+ failed'   | grep -oE '^[0-9]+' | tail -1)"
  n_skip="$(printf '%s\n' "$out" | grep -oE '[0-9]+ skipped'  | grep -oE '^[0-9]+' | tail -1)"
  n_err="$(printf  '%s\n' "$out" | grep -oE '[0-9]+ errors?'  | grep -oE '^[0-9]+' | tail -1)"
  n_pass="${n_pass:-0}"; n_fail="${n_fail:-0}"
  n_skip="${n_skip:-0}"; n_err="${n_err:-0}"
  n_collect="$(printf '%s\n' "$out" | grep -oE 'collected [0-9]+' | grep -oE '[0-9]+' | tail -1)"

  if [ "$rc" -ne 0 ]; then
    ac_fail "$id" "pytest exited $rc (${n_pass} passed, ${n_fail} failed, ${n_skip} skipped, ${n_err} error)"
    return 1
  fi
  if [ "$n_skip" -ne 0 ]; then
    ac_fail "$id" "pytest exited 0 but ${n_skip} test(s) skipped — a skipped test is not a passing test"
    return 1
  fi
  if [ -n "$n_collect" ] && [ "$n_collect" -ne "$n_pass" ]; then
    ac_fail "$id" "collected ${n_collect} but only ${n_pass} passed"
    return 1
  fi
  if [ "$n_pass" -eq 0 ]; then
    ac_fail "$id" "pytest exited 0 but collected no tests"
    return 1
  fi

  ac_pass "$id" "pytest: ${n_pass} passed, 0 skipped, collected == passed"
  return 0
}

# ac_check_dec6 [id]
#
# Greps every tracked file for $AMP_DEC6_PATTERN, the disclosure denylist. The
# pattern lives in the environment and never in a tracked file, because a
# denylist enumerates precisely what it protects.
#
# Before this helper existed the scan was hand-rolled in four packet gates with
# four different path lists and two different reporting behaviours, and not one
# of them looked at .agents/ — which is tracked, and is where the only real leak
# actually landed. The point of the helper is that widening it now happens once.
#
# Three verdicts, and the reasoning for each:
#
#   pattern unset  WEAK, never PASS. An unconfigured machine must not be able to
#                  mistake a check that did not run for one that found nothing.
#   no match       PASS. The check is direct — it reads the published set itself,
#                  not a proxy for it.
#   match          FAIL, naming the files. Three of the four legacy copies
#                  reported a bare boolean, which tells a reader that something
#                  is wrong and not where.
#
# The scanned set is the tracked set: `git grep` searches the files in the index
# and nothing else. That is the definition of "published" DEC-6 cares about, and
# it disposes of the exclusion problem for free — .git/, __pycache__/ and
# .untracked/ (which holds the private notes by design and would otherwise make
# every scan fail) are all outside it, with nobody maintaining a list.
#
# Paths are a surface of their own, not merely a way of naming file contents. A
# directory named after a host is in the published tree objects whether or not
# any file mentions it, and unlike a content leak it cannot be fixed by editing
# a file — remediation is a rename, and the old path stays in history. So the
# surface the scan was missing is the one that is harder to clean up after. Path
# findings are reported with a `path:` prefix, because "this file matched" and
# "this file's name matched" call for different remediation and a bare list
# would conflate them.
#
# The two surfaces necessarily run different regex engines — git grep's for
# contents, POSIX ERE for the path list, since git grep matches file *contents*
# and has no mode that regex-matches names. Measured rather than assumed: the
# engines agree on the alternation of literal terms a denylist actually is, and
# a test drives an alternation across both surfaces to keep that true. They do
# diverge on exotic syntax, so a pattern using more than alternation and
# anchoring would want re-measuring on both surfaces before being trusted.
#
# Both the working tree and the index are read. They differ in one direction
# each: a leak written into a tracked file but not yet committed is only in the
# working tree, and a tracked file deleted from the working tree but still in
# the index is only in the index — and the latter is still published until the
# deletion is committed. Two cheap passes cover both; one would have a silent
# blind spot in whichever direction it skipped.
#
# Unlike ac_check_write_scope, this keeps evaluating in an archived packet and
# keeps gating there. A completed packet's declared scope stopped describing
# anything the moment it completed, so evaluating it would be noise; a leak in
# the tracked tree is a real leak whoever introduced it and whenever, so
# evaluating it is the point. The divergence is deliberate.
#
# Only the framework root is scanned. In a sidecar the code root is the client's
# own repository, published under its own policy, and a denylist hit there is
# not this gate's finding — an unclearable FAIL in a repository the framework
# does not own is a gate whose only escape is to stop gating. The verdict names
# which root was read, so the narrower surface is stated rather than assumed.
#
# The matched text is never printed: the pattern is the thing being protected,
# so the message carries filenames and counts and nothing else. For the same
# reason set-ness is reported by branching rather than by expanding the variable
# into a string — a safe idiom composed with an unsafe one is unsafe.
ac_check_dec6() {
  local id="${1:-DEC-6}"

  _ac_roots_ok "$id" || return 1

  if [ -z "${AMP_DEC6_PATTERN:-}" ]; then
    ac_weak "$id" "the leak pattern is not configured (AMP_DEC6_PATTERN unset or empty) — no scan ran"
    return 0
  fi

  local root="$AC_FRAMEWORK_ROOT"
  if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ac_weak "$id" "no git repository at $root, so the tracked-file set is unknowable — no scan ran"
    return 0
  fi

  local tracked scanned tree_hits index_hits path_hits rc_tree rc_index rc_path
  tracked="$(git -C "$root" ls-files 2>/dev/null)"
  if [ -z "$tracked" ]; then
    scanned=0
  else
    scanned="$(printf '%s\n' "$tracked" | wc -l | tr -d ' ')"
  fi

  # -I skips binary files, which cannot leak prose and whose match would print
  # as a bare "Binary file ... matches" line.
  tree_hits="$(git -C "$root" grep -l -I -i -E -e "$AMP_DEC6_PATTERN" -- 2>/dev/null)"
  rc_tree=$?
  index_hits="$(git -C "$root" grep --cached -l -I -i -E -e "$AMP_DEC6_PATTERN" -- 2>/dev/null)"
  rc_index=$?
  path_hits="$(printf '%s\n' "$tracked" | grep -i -E -e "$AMP_DEC6_PATTERN" 2>/dev/null)"
  rc_path=$?

  # 0 is "matched", 1 is "did not match"; anything else is the scan failing,
  # which must not read as clean. The path pass is held to the same rule: a
  # malformed pattern makes plain grep exit 2 exactly as it makes git grep
  # exit 128, and a surface that errored is not a surface that came back clean.
  if [ "$rc_tree" -gt 1 ] || [ "$rc_index" -gt 1 ] || [ "$rc_path" -gt 1 ]; then
    ac_weak "$id" "grep exited $rc_tree (tree) / $rc_index (index) / $rc_path (paths) over $scanned tracked file(s) — the scan did not complete"
    return 0
  fi

  local content_matches path_matches findings
  content_matches="$(printf '%s\n%s\n' "$tree_hits" "$index_hits" | grep -v '^$' | sort -u)"
  path_matches="$(printf '%s\n' "$path_hits" | grep -v '^$' | sort -u | sed 's|^|path:|')"
  findings="$(printf '%s\n%s\n' "$content_matches" "$path_matches" | grep -v '^$')"

  local root_note=""
  _ac_single_root || root_note=" (framework root only; the code root is a separate repository under its own disclosure policy)"

  if [ -z "$findings" ]; then
    ac_pass "$id" "no leak-pattern match in the contents or paths of $scanned tracked file(s)$root_note"
    return 0
  fi

  # Counted as findings rather than as files: one file can match on both its
  # contents and its name, and those are two things to fix, not one.
  local n shown
  n="$(printf '%s\n' "$findings" | wc -l | tr -d ' ')"
  shown="$(printf '%s\n' "$findings" | head -20 | tr '\n' ' ')"
  shown="${shown% }"
  [ "$n" -gt 20 ] && shown="$shown … and $((n - 20)) more"
  ac_fail "$id" "leak pattern matched $n finding(s) across $scanned tracked file(s)$root_note: $shown"
  return 1
}

# ac_grep_foreign <id> <file> <pattern> [description] [negative-fixture]
#
# A text-presence assertion about a file the packet does not own. Reports WEAK
# in every branch — present, absent, file missing, grep failed — each with its
# own message, and never gates in either direction.
#
# WEAK on a match, because a grep for a sentence is a snapshot by construction:
# any rewording breaks it, and the rewording is usually an improvement. A match
# establishes that some prose is there, not that the property it stands for
# still holds. That is exactly the "can report success on input lacking the
# property" case ac_weak exists for.
#
# WEAK on no match, because the packet does not own the file and later work is
# entitled to rewrite it. The instance that produced this helper:
# iv_client-verification asserted that upgrade-project carries the sentence "Do
# not run this skill against a sidecar install", and P1.1b then superseded that
# prohibition by adding sidecar support. The gate went red, stayed red for three
# days before anyone noticed, and the only way to clear it literally was to put
# a false statement back into a shipped skill. A gate whose sole remedy is to
# make a shipped file wrong must not gate.
#
# One call asserts one string. What this replaces was a conjunction of two greps
# reported as a single FAIL, so a reader could not tell which half was missing —
# and the two halves had opposite answers: one assertion was obsolete and one
# was a real loss nobody had decided about. The conjunction is what made the
# failure illegible, so the per-call granularity is the fix, not a detail of it.
#
# Rejected: expiring foreign assertions on archival, the way ac_check_write_scope
# drops its SCOPE line. A completed packet's declared write scope stopped
# describing anything the moment it completed, but "the skill still warns about
# X" can stay meaningful indefinitely. The claim is worth reporting after
# archival — just not worth gating on.
#
# Deliberately no _ac_roots_ok guard, unlike every other public check here. This
# one reads no root: the caller passes a path it has already resolved. Adding
# the guard would also give the helper an ac_fail branch, which is precisely the
# property it is defined not to have. Do not add it back for consistency.
#
# Matching is fixed-string. The assertions this exists for are sentences, and a
# sentence is far likelier to contain an accidental metacharacter than a
# deliberate one.
#
# Argument 5 is reserved for a negative fixture — a file the pattern must *not*
# match — so that a text-presence check can carry its own control as a
# parameter rather than as a separate discipline. The discipline it would
# automate: an instrument that has not been exercised against the condition it
# detects has not been verified, so a pattern shown only to match has been shown
# to produce output, not to discriminate. Unimplemented on purpose: it
# changes the cost of writing every WEAK check in the framework, which is a
# discipline change rather than a scan fix, and it is parked as ac_grep_verified.
# Accepting it as a trailing optional argument now means adding it later will not
# break callers.
ac_grep_foreign() {
  local id="${1:-FOREIGN}" file="${2:-}" pattern="${3:-}" label="${4:-}"

  if [ -z "$file" ] || [ -z "$pattern" ]; then
    ac_weak "$id" "ac_grep_foreign was called without a file or a pattern — nothing was read"
    return 0
  fi
  [ -z "$label" ] && label="$pattern"

  if [ ! -f "$file" ]; then
    ac_weak "$id" "$label: no file at $file — neither present nor absent, because nothing was read"
    return 0
  fi

  local rc
  grep -q -F -e "$pattern" "$file" 2>/dev/null
  rc=$?

  # 0 is "matched", 1 is "did not match"; anything else is grep failing, which
  # must not read as a clean absence. Same rule as ac_check_dec6 applies to a
  # verdict class that cannot express it — so the message carries the exit code.
  if [ "$rc" -gt 1 ]; then
    ac_weak "$id" "$label: grep exited $rc reading $file — the check did not complete"
  elif [ "$rc" -eq 0 ]; then
    ac_weak "$id" "$label: present in $file (text presence in a file this packet does not own)"
  else
    ac_weak "$id" "$label: absent from $file — later work is entitled to rewrite it, so this does not gate"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The judgement-engine seam
# ---------------------------------------------------------------------------
#
# When AMP_AC_VALIDATOR names an executable, ac_finish invokes it once with
#
#   {"workflow_id","dossier_path","repo_root",
#    "criteria":[{"id","text","reason"}, ...]}
#
# on stdin, and reads
#
#   {"verdicts":[{"id","verdict","rationale"}, ...]}   verdict: pass|fail|unknown
#
# from stdout. A `fail` converts that criterion to FAIL and gates the exit
# code; `unknown` leaves it JUDGE; `pass` clears it. The validator lives
# outside this repository — the seam is here so the convention does not have to
# change when it arrives.
_ac_run_validator() {
  local validator="${AMP_AC_VALIDATOR:-}"
  [ -z "$validator" ] && return 0
  if [ ! -x "$validator" ]; then
    printf 'JUDGE %-8s %s\n' "VALIDATOR" \
      "AMP_AC_VALIDATOR set but not executable: $validator (judgement criteria left unresolved)"
    return 0
  fi
  [ "${#AC_JUDGE_IDS[@]}" -eq 0 ] && return 0

  local payload response
  local args=() i
  for ((i = 0; i < ${#AC_JUDGE_IDS[@]}; i++)); do
    args+=("${AC_JUDGE_IDS[$i]}" "${AC_JUDGE_TEXTS[$i]}" "${AC_JUDGE_REASONS[$i]}")
  done
  payload="$(
    AC_WORKFLOW_ID="${AC_WORKFLOW_ID:-}" \
    AC_DOSSIER_PATH="${AC_DOSSIER_PATH:-}" \
    AC_ROOT="$AC_REPO_ROOT" \
    python3 -c '
import json, os, sys
a = sys.argv[1:]
json.dump({
    "workflow_id":  os.environ.get("AC_WORKFLOW_ID", ""),
    "dossier_path": os.environ.get("AC_DOSSIER_PATH", ""),
    "repo_root":    os.environ.get("AC_ROOT", ""),
    "criteria": [
        {"id": a[i], "text": a[i + 1], "reason": a[i + 2]}
        for i in range(0, len(a), 3)
    ],
}, sys.stdout)
' "${args[@]}"
  )"

  response="$(printf '%s' "$payload" | "$validator" 2>/dev/null)"
  if [ -z "$response" ]; then
    printf 'JUDGE %-8s %s\n' "VALIDATOR" "validator produced no output; judgement criteria left unresolved"
    return 0
  fi

  # Emit one "<id> <verdict> <rationale>" line per verdict, then apply.
  local parsed
  parsed="$(printf '%s' "$response" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(3)
for v in data.get("verdicts", []):
    vid = str(v.get("id", "")).strip()
    verdict = str(v.get("verdict", "unknown")).strip().lower()
    rationale = " ".join(str(v.get("rationale", "")).split())
    if vid:
        print(f"{vid}\t{verdict}\t{rationale}")
' 2>/dev/null)"
  if [ -z "$parsed" ]; then
    printf 'JUDGE %-8s %s\n' "VALIDATOR" "validator output was not parseable; judgement criteria left unresolved"
    return 0
  fi

  local vid verdict rationale
  while IFS=$'\t' read -r vid verdict rationale; do
    [ -z "$vid" ] && continue
    case "$verdict" in
      fail)
        printf 'FAIL  %-8s %s\n' "$vid" "validator: ${rationale:-judgement criterion rejected}"
        AC_FAIL_COUNT=$((AC_FAIL_COUNT + 1))
        AC_JUDGE_COUNT=$((AC_JUDGE_COUNT - 1))
        ;;
      pass)
        printf 'PASS  %-8s %s\n' "$vid" "validator: ${rationale:-judgement criterion accepted}"
        AC_PASS_COUNT=$((AC_PASS_COUNT + 1))
        AC_JUDGE_COUNT=$((AC_JUDGE_COUNT - 1))
        ;;
      *)
        printf 'JUDGE %-8s %s\n' "$vid" "validator: unknown — ${rationale:-no rationale}"
        ;;
    esac
  done <<< "$parsed"
  return 0
}

# ---------------------------------------------------------------------------
# ac_finish — summary and exit code
# ---------------------------------------------------------------------------
#
# Exits 0 if and only if zero FAIL lines were emitted. WEAK and JUDGE never
# gate: a weak check is still a check, and a judgement criterion is a human's
# call. Both are reported so that neither disappears.
ac_finish() {
  _ac_run_validator

  echo
  printf '%d passed, %d weak, %d judgement, %d failed\n' \
    "$AC_PASS_COUNT" "$AC_WEAK_COUNT" "$AC_JUDGE_COUNT" "$AC_FAIL_COUNT"

  if [ "$AC_FAIL_COUNT" -gt 0 ]; then
    echo "ACCEPTANCE FAILED"
    exit 1
  fi
  if [ "$AC_WEAK_COUNT" -gt 0 ] || [ "$AC_JUDGE_COUNT" -gt 0 ]; then
    echo "ACCEPTANCE PASSED (with $AC_WEAK_COUNT weak, $AC_JUDGE_COUNT judgement — human review required)"
  else
    echo "ACCEPTANCE PASSED"
  fi
  exit 0
}

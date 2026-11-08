#!/usr/bin/env bash
#
# leak-scan.sh — the DEC-6 pre-push control.
#
#   scripts/leak-scan.sh [<commit-range>]
#
# Scans everything a push would publish for $AMP_DEC6_PATTERN, the disclosure
# denylist, and exits non-zero if anything matches. With no argument the range
# is <upstream>..HEAD.
#
# Why this exists as well as the packet gates. A packet's acceptance.sh runs
# when someone runs that packet; the risk DEC-6 names is a *push*, and those two
# events are unrelated. The 2026-08-14 audit that found the guard was itself a
# disclosure was done by hand, and the scan has since been hand-rebuilt three
# times, each rebuild reintroducing a defect an earlier one had fixed. This is
# that scan, owned by the repository.
#
# FOUR SURFACES, because a push publishes more than a diff:
#
#   added lines      per commit, never as a range diff — see below
#   commit messages  no file scan reaches them, and history keeps them
#   touched paths    a directory named after a host is published in the tree
#                    objects whether or not any file mentions it
#   the tracked tree ac_check_dec6, the same helper the packet gates call
#
# ITERATE COMMITS, DO NOT DIFF THE RANGE. `git diff A..B` reports the *net*
# effect, so a line added by one commit and removed by a later one is invisible
# to it — and the push publishes the commits, not the net. Measured on this
# repository 2026-08-17: 647 added lines by range diff against 738 by per-commit
# sum, a 91-line blind spot from three created-then-deleted files and one
# rename.
#
# NEVER READ FILE LISTS OUT OF `--stat`. It abbreviates long paths with a
# leading `...`, which is a silent false negative — a real one, on 2026-08-17,
# which is what let a wrong attribution survive the check meant to catch it.
# `--numstat` emits full paths and is used throughout.
#
# RENAME DETECTION IS OFF, deliberately. `-M` reports a rename as one tidy
# entry under the new name, but the old path is in the published history and is
# exactly as disclosed as the new one. `--no-renames` shows both.
#
# DISCLOSURE RULE, binding on every line of this file: the pattern is the thing
# being protected, so it is never printed and never expanded into a string that
# gets printed. Findings carry shas and paths and nothing else — in particular a
# matching commit message is reported by sha, never quoted, because quoting it
# would republish the leak into the scan's own output. To report set-ness,
# branch. A safe idiom composed with an unsafe one is unsafe.
#
# ACCEPTED-FINDINGS BASELINE (omniprobe addition, owner decision D1,
# 2026-11-08). Findings the owner has accepted rather than fixed — already
# published, history not rewritten — are listed in scripts/leak-scan-baseline.txt
# and are not reported. The baseline is itself a tracked file, so it must never
# contain the matched text: entries are keyed by path and a SHA-256 of the
# matching line (tree), or by full commit sha, surface and path (range). A new
# match — a new line, or an edit to an accepted line — hashes differently and is
# reported. `--print-baseline` emits entries for the current findings, for an
# owner to review and append; it prints hashes, shas and paths only.
#
#   scripts/leak-scan.sh [--print-baseline] [<commit-range>]

set -u -o pipefail

print_baseline=0
if [ "${1:-}" = "--print-baseline" ]; then
  print_baseline=1
  shift
fi

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

# Unset exits non-zero, which is deliberately stronger than the packet gate's
# WEAK for the same condition. A gate's WEAK is read by someone looking at a
# verdict list; this guards a push, and a push cannot be reviewed afterwards.
# Exit 2 rather than 1 so "did not run" is distinguishable from "found
# something" by a caller that only sees the status.
if [ -z "${AMP_DEC6_PATTERN:-}" ]; then
  echo "leak-scan: AMP_DEC6_PATTERN is not configured — no scan ran." >&2
  echo "leak-scan: refusing to report a clean push from a check that did not run." >&2
  exit 2
fi

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || repo=""
if [ -z "$repo" ]; then
  echo "leak-scan: not inside a git repository." >&2
  exit 2
fi

range="${1:-}"
if [ -z "$range" ]; then
  # No upstream is not an error to guess around. A wrong base silently scans the
  # wrong set of commits and reports clean, which is the failure this whole
  # script exists to prevent.
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || upstream=""
  if [ -z "$upstream" ]; then
    echo "leak-scan: no upstream is configured for this branch, so there is no range to derive." >&2
    echo "leak-scan: pass one explicitly, e.g. scripts/leak-scan.sh <remote>/<branch>..HEAD" >&2
    exit 2
  fi
  range="$upstream..HEAD"
fi

if ! commits="$(git rev-list "$range" 2>/dev/null)"; then
  echo "leak-scan: not a valid commit range: $range" >&2
  exit 2
fi

echo "leak-scan: range $range in $repo"

baseline_file="${LEAK_SCAN_BASELINE:-$repo/scripts/leak-scan-baseline.txt}"
baseline=""
if [ -f "$baseline_file" ]; then
  baseline="$(grep -v -e '^#' -e '^[[:space:]]*$' "$baseline_file")"
fi
n_accepted=0
new_baseline=""

accepted() {                      # accepted <baseline-entry>
  [ -n "$baseline" ] && printf '%s\n' "$baseline" | grep -qxF -e "$1"
}

# ---------------------------------------------------------------------------
# The range surfaces
# ---------------------------------------------------------------------------

n_commits=0
n_lines=0
n_messages=0
findings=""

add_finding() {                   # add_finding <sha> <surface> <detail> [<baseline-entry>]
  if [ -n "${4:-}" ]; then
    if accepted "$4"; then
      n_accepted=$((n_accepted + 1))
      return
    fi
    new_baseline="${new_baseline}$4"$'\n'
  fi
  findings="${findings}  $1  $2  $3"$'\n'
}

while IFS= read -r commit; do
  [ -z "$commit" ] && continue
  n_commits=$((n_commits + 1))
  short="$(git rev-parse --short "$commit")"

  # -- commit message ------------------------------------------------------
  #
  # Counted independently of the commit count rather than assumed equal to it.
  # If this pass breaks, `N commits` and `0 messages` disagree visibly, where a
  # single number would have reported a scan that never ran as one that found
  # nothing.
  message="$(git show -s --format='%B' "$commit")"
  n_messages=$((n_messages + 1))
  if printf '%s\n' "$message" | grep -qiE -e "$AMP_DEC6_PATTERN"; then
    add_finding "$short" "commit-message" "(text withheld — read it with: git show -s --format=%B $short)" \
      "commit $commit commit-message -"
  fi

  # -- touched paths and added lines --------------------------------------
  #
  # -m shows a merge against each parent rather than nothing at all, so content
  # introduced by a conflict resolution is scanned. A merge's lines are then
  # counted once per parent; the census is a measure of how much was read, not
  # a diff statistic.
  while IFS=$'\t' read -r _added _deleted path; do
    [ -z "${path:-}" ] && continue

    if printf '%s\n' "$path" | grep -qiE -e "$AMP_DEC6_PATTERN"; then
      add_finding "$short" "path" "$path" "commit $commit path $path"
    fi

    # Added lines for this file alone, so a matching *path* cannot be misread
    # as matching *contents*. Scanning the whole commit's diff in one pass and
    # attributing hits to a filename column would report exactly that false
    # positive, and the two call for different fixes: an edit versus a rename.
    added="$(git show --format= --unified=0 --no-renames -m "$commit" -- "$path" \
             | grep '^+' | grep -v '^+++')"
    [ -z "$added" ] && continue
    n_lines=$((n_lines + $(printf '%s\n' "$added" | wc -l)))
    if printf '%s\n' "$added" | grep -qiE -e "$AMP_DEC6_PATTERN"; then
      add_finding "$short" "added-line" "$path" "commit $commit added-line $path"
    fi
  done < <(git show --format= --numstat --no-renames -m "$commit")
done <<EOF
$commits
EOF

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

status=0

if [ -n "$findings" ]; then
  echo "leak-scan: FINDINGS in the range —"
  printf '%s' "$findings" | sort -u
  status=1
fi

# The census. A clean result and a broken pipeline both render as no findings,
# and this line is what tells them apart: an empty range says so with zeroes
# rather than with silence. The form is fixed by the packet's AC-11 so that the
# criterion and this line cannot drift.
echo "scanned: $n_commits commits, $n_lines lines, $n_messages messages"

# ---------------------------------------------------------------------------
# The tracked tree, via the same helper the packet gates call
# ---------------------------------------------------------------------------
#
# The range is what this push adds; the tree is what the repository currently
# publishes. They differ whenever something reached the tree without being in
# this range, which is every already-pushed commit. Both were surfaces of every
# hand-run pre-push check on record, so both are here.
#
# Resolved from this script's own location, never from the working directory:
# the 2026-08-10 lesson is that path resolution breaks exactly when a file is
# run from somewhere new. AMP_AC_REPO_ROOT is then pointed at the repository
# being scanned, which is the one the range came from and not the one the
# script happens to live in.

if [ -f "$baseline_file" ]; then
  # Line-level scan, so each match can be checked against the baseline. Same
  # surfaces as ac_check_dec6: working-tree contents, index contents, and
  # tracked paths. -z keeps paths containing ':' unambiguous.
  tree_findings=""
  n_tree_accepted=0
  scan_rc=0
  for where in "" "--cached"; do
    hits="$(git -C "$repo" grep $where -z -n -I -i -E -e "$AMP_DEC6_PATTERN" -- 2>/dev/null | tr '\0\n' '\t\0' | tr '\0' '\n')"
    rc=$?
    [ "$rc" -gt 1 ] && scan_rc=$rc
    while IFS=$'\t' read -r path lineno content; do
      [ -z "${path:-}" ] && continue
      hash="$(printf '%s' "$content" | sha256sum | cut -d' ' -f1)"
      entry="tree $path $hash"
      if accepted "$entry"; then
        n_tree_accepted=$((n_tree_accepted + 1))
      else
        tree_findings="${tree_findings}  $path:$lineno${where:+ (index)}"$'\n'
        new_baseline="${new_baseline}$entry"$'\n'
      fi
    done <<<"$hits"
  done
  path_hits="$(git -C "$repo" ls-files | grep -i -E -e "$AMP_DEC6_PATTERN")"
  rc=$?
  [ "$rc" -gt 1 ] && scan_rc=$rc
  if [ -n "$path_hits" ]; then
    # Never baselined: a path cannot be hashed without the hash standing in
    # for the name everywhere it is listed.
    tree_findings="${tree_findings}$(printf '%s\n' "$path_hits" | sed 's|^|  path:|')"$'\n'
  fi
  n_tracked="$(git -C "$repo" ls-files | wc -l | tr -d ' ')"
  if [ "$scan_rc" -gt 1 ]; then
    echo "FAIL  TREE     grep exited $scan_rc — the tracked-tree scan did not complete"
    status=1
  elif [ -n "$tree_findings" ]; then
    echo "FAIL  TREE     leak pattern matched outside the baseline in $n_tracked tracked file(s):"
    printf '%s' "$tree_findings" | sort -u
    status=1
  else
    echo "PASS  TREE     no leak-pattern match outside the baseline in $n_tracked tracked file(s)"
  fi
  echo "baseline: $baseline_file — $n_accepted range and $n_tree_accepted tree match(es) accepted"
else
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.agents/hooks/acceptance-lib.sh"
  if [ -f "$lib" ]; then
    export AMP_AC_REPO_ROOT="$repo"
    # shellcheck source=/dev/null
    source "$lib"
    ac_check_dec6 "TREE" || status=1
  else
    echo "WEAK  TREE     acceptance library not found at $lib — the tracked-tree surface was not scanned"
  fi
fi

if [ "$print_baseline" -eq 1 ] && [ -n "$new_baseline" ]; then
  echo "leak-scan: baseline entries for the unaccepted findings above —"
  printf '%s' "$new_baseline" | sort -u
fi

if [ "$status" -eq 0 ]; then
  echo "leak-scan: clean."
else
  echo "leak-scan: NOT clean — resolve the findings above before pushing."
fi
exit "$status"

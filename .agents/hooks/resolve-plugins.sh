#!/usr/bin/env bash
#
# resolve-plugins.sh — resolve the plugins declared in .agents/project.json.
#
# Prints one `Plugins:` line when at least one plugin is declared, and nothing
# at all when none is. See docs/usage/plugins.md for the user-facing statement.
#
# Three properties this file exists to guarantee, in order of importance:
#
#   1. It always exits 0. This runs at the start of every session in every
#      install, so a plugin that has moved, vanished, or was never cloned must
#      degrade to a line of text. The framework must not depend on a plugin
#      existing, and this must not become a new way for session-init to fail.
#   2. It never writes. Not to the plugin, not to the declaring repository, not
#      to a cache. The version and the active count are facts that expire, so
#      they are derived when read and recorded nowhere — the same shape as the
#      `Unpushed:` field in the session-init briefing.
#   3. It reads project.json with grep/sed/awk rather than python3, following
#      the decision recorded in acceptance-lib.sh: the file is machine-written
#      by amplify.py with a fixed shape, and a client repo need not be a Python
#      project to run a hook that fires at every session start.

set -u

# Resolved from this script's own location rather than from the working
# directory or `git rev-parse`: the hook lives at <root>/.agents/hooks/, so
# this is correct regardless of where it is invoked from and whether the
# repository is a git repository at all.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pj="$root/.agents/project.json"
[ -f "$pj" ] || exit 0

# Capture the `plugins` array, which json.dumps(indent=2) writes across several
# lines. Accumulates from just after the key to the first `]`, then extracts the
# quoted strings in file order — `grep -o` preserves order, which is what makes
# declaration order meaningful rather than incidental.
raw="$(awk '
  /"plugins"[[:space:]]*:/ { sub(/.*"plugins"[[:space:]]*:[[:space:]]*/, ""); f = 1 }
  f { printf "%s", $0; if (index($0, "]")) exit }
' "$pj" 2>/dev/null)"

[ -n "$raw" ] || exit 0

entries=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue

  case "$rel" in
    /*) dir="$rel" ;;
    *)  dir="$root/$rel" ;;
  esac
  name="${rel##*/}"

  if [ ! -d "$dir" ]; then
    entry="$name (not found)"
  elif [ ! -f "$dir/.agents/project.json" ]; then
    # Something is there, but it is not an amplified repository. Distinguished
    # from "not found" on purpose: the two have different fixes, and collapsing
    # them would send someone looking for a missing clone that is present.
    entry="$name (no .agents/project.json)"
  else
    version="$(sed -n 's/.*"amplify_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$dir/.agents/project.json" 2>/dev/null | head -1)"
    [ -n "$version" ] || version="?"

    active=0
    if [ -d "$dir/.agents/workflows/active" ]; then
      for wf in "$dir/.agents/workflows/active"/*/; do
        [ -d "$wf" ] && active=$((active + 1))
      done
    fi

    entry="$name (v$version, $active active)"
  fi

  if [ -z "$entries" ]; then
    entries="$entry"
  else
    entries="$entries, $entry"
  fi
done < <(printf '%s' "$raw" | grep -oE '"[^"]*"' | sed 's/^"//; s/"$//')

[ -n "$entries" ] && printf 'Plugins: %s\n' "$entries"

exit 0

#!/usr/bin/env bash
# Print the CHANGELOG.md section for a version, for use as GitHub release notes.
#
# Usage: scripts/release_notes.sh 2026.07.14
#
# Fails loudly on a missing section: a release whose notes silently came out
# empty is worse than one that didn't publish.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: $0 <version>}"

NOTES="$(awk -v header="## [$VERSION]" '
    index($0, header) == 1 { found = 1; next }
    found && /^## \[/      { exit }
    found                  { print }
' CHANGELOG.md)"

# Strip leading/trailing blank lines; complain if there was nothing but those.
NOTES="$(printf '%s\n' "$NOTES" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"
[ -n "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ] || {
    echo "✗ no '## [$VERSION]' section in CHANGELOG.md — add one before releasing" >&2
    exit 1
}

printf '%s\n' "$NOTES"

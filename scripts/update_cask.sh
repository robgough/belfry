#!/usr/bin/env bash
# Bump the Homebrew cask after a macOS release: point it at the new version and
# checksum, then commit + push the tap. Run this AFTER `gh release create` has
# uploaded the zip (the cask URL points at the release asset).
#
# Usage: scripts/update_cask.sh [version] [zip]
#
# Version defaults to the newest Belfry-*.zip in the repo root (the macOS
# artifact scripts/release.sh just built — not the newest v* tag, which may be
# an iOS-only release with no zip). The tap is a separate repo
# (github.com/robgough/homebrew-belfry); point BELFRY_TAP at a local clone
# (default: ../homebrew-belfry) — the script clones it there if it's missing.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    ZIP="$(ls -1 Belfry-*.zip 2>/dev/null \
        | sed -E 's/^Belfry-(.*)\.zip$/\1/' \
        | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
    VERSION="$ZIP"
    [ -n "$VERSION" ] || { echo "no Belfry-*.zip found (run scripts/release.sh first)" >&2; exit 1; }
    echo "› version $VERSION (newest built Belfry-*.zip)"
fi
ZIP="${2:-Belfry-$VERSION.zip}"
[ -f "$ZIP" ] || { echo "no zip: $ZIP (run scripts/release.sh first)" >&2; exit 1; }

TAP="${BELFRY_TAP:-$(cd .. && pwd)/homebrew-belfry}"
if [ ! -d "$TAP/.git" ]; then
    echo "› cloning tap into $TAP"
    git clone git@github.com:robgough/homebrew-belfry.git "$TAP"
fi
CASK="$TAP/Casks/belfry.rb"
[ -f "$CASK" ] || { echo "no cask at $CASK" >&2; exit 1; }

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "› $ZIP → sha256 $SHA"

# Targeted line edits so everything else in the cask (zap paths, deps…) is kept.
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/"  "$CASK"
sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$SHA\"/"        "$CASK"

# Sanity-check the result before publishing (skip if brew is absent).
if command -v brew >/dev/null; then
    brew style "$CASK"
fi

git -C "$TAP" pull --quiet --ff-only || true
git -C "$TAP" add Casks/belfry.rb
if git -C "$TAP" diff --cached --quiet; then
    echo "✓ cask already at $VERSION — nothing to push"
    exit 0
fi
git -C "$TAP" commit -q -m "Belfry $VERSION"
git -C "$TAP" push -q
echo "✓ cask bumped to $VERSION and pushed — users get it on next 'brew upgrade'"

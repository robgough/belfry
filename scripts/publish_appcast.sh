#!/usr/bin/env bash
# Sign and publish the Sparkle appcast for a release.
#
# Usage: scripts/publish_appcast.sh <version> [--generate-only]
#
# This is the step that actually ships to existing installs: Sparkle reads
# docs/appcast.xml from belfry.robgough.net (GitHub Pages), and only trusts
# entries EdDSA-signed by the key in the login keychain. That key deliberately
# lives here and not in GitHub Actions — CI can build, sign, notarize and
# publish a release, but it cannot make every install auto-update itself.
# See RELEASING.md.
#
# Needs the exact bytes users will download, so the signature and length
# describe the published asset: uses ./Belfry-<version>.zip when it's already
# here (the local release.sh flow), otherwise fetches what CI attached to the
# release.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=""
GENERATE_ONLY=""
for arg in "$@"; do
    case "$arg" in
        --generate-only) GENERATE_ONLY=1 ;;
        *) VERSION="$arg" ;;
    esac
done
[ -n "$VERSION" ] || { echo "usage: $0 <version> [--generate-only]" >&2; exit 2; }

ZIP="Belfry-$VERSION.zip"
if [ ! -f "$ZIP" ]; then
    URL="https://github.com/robgough/belfry/releases/download/v$VERSION/$ZIP"
    echo "› no local $ZIP — fetching the release asset"
    curl -fsSL -o "$ZIP" "$URL" \
        || { echo "✗ no asset at $URL — has the release finished?" >&2; rm -f "$ZIP"; exit 1; }
fi

SPARKLE_BIN=".build/sparkle-tools/bin"
if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
    echo "› fetching Sparkle tools…"
    mkdir -p .build/sparkle-tools
    curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/2.9.3/Sparkle-2.9.3.tar.xz" \
        | tar -xJ -C .build/sparkle-tools
fi

STAGE=".build/appcast-stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp "$ZIP" "$STAGE/"
"$SPARKLE_BIN/generate_appcast" "$STAGE" \
    --download-url-prefix "https://github.com/robgough/belfry/releases/download/v$VERSION/" \
    --link "https://belfry.robgough.net" \
    --full-release-notes-url "https://github.com/robgough/belfry/releases" \
    -o docs/appcast.xml

if [ -n "$GENERATE_ONLY" ]; then
    echo "✓ docs/appcast.xml regenerated (not committed)"
    exit 0
fi

if git diff --quiet -- docs/appcast.xml; then
    echo "✓ appcast already current for $VERSION — nothing to publish"
    exit 0
fi

git add docs/appcast.xml
git commit -q -m "Appcast for $VERSION"
git push -q
echo "› pushed docs/appcast.xml"

# Ask for the Pages build rather than assume the push triggers one: for
# 2026.07.14 it silently didn't (no build ran, no incident, feed stayed stale
# for 25 minutes), and a push made by CI's token never triggers one by design.
# Sparkle only sees the release once Pages republishes, so make it explicit.
if command -v gh >/dev/null && gh api -X POST repos/robgough/belfry/pages/builds --silent 2>/dev/null; then
    echo "✓ appcast published; Pages build requested — Sparkle sees $VERSION within a minute or two"
else
    echo "⚠ appcast pushed, but couldn't request a Pages build (gh missing or unauthenticated)."
    echo "  Check https://github.com/robgough/belfry/actions for 'pages build and deployment',"
    echo "  and verify: curl -s https://belfry.robgough.net/appcast.xml | grep shortVersionString"
fi

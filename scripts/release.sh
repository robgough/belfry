#!/usr/bin/env bash
# Build, sign, notarize and staple a distributable Belfry.app, producing
# Belfry-<version>.zip ready to attach to a GitHub release.
#
# Usage: scripts/release.sh [version] [--skip-notarize]
#
# Version defaults to the next calendar release (YYYY.MM.N, N = nth release
# this month across both platforms), derived from existing v* tags — which
# is why releases must be tagged (see RELEASING.md).
#
# Needs in the keychain:
#   - a "Developer ID Application" identity (override with SIGN_IDENTITY=<hash>
#     if more than one matches)
#   - a notarytool credentials profile (one-time setup:
#       xcrun notarytool store-credentials belfry-notary \
#         --apple-id <apple-id> --team-id 5Z5EG95CQL
#     override the profile name with NOTARY_PROFILE=<name>)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=""
SKIP_NOTARIZE=""
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE="--skip-notarize" ;;
        *) VERSION="$arg" ;;
    esac
done
if [ -z "$VERSION" ]; then
    YM="$(date +%Y.%m)"
    LAST="$(git tag --list "v$YM.*" | sed "s/^v$YM\.//" | sort -n | tail -1)"
    VERSION="$YM.$((${LAST:-0} + 1))"
    echo "› version $VERSION (next untagged $YM release)"
fi
PROFILE="${NOTARY_PROFILE:-belfry-notary}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
BUILD_NUM="$(git rev-list --count HEAD)"
ZIP="Belfry-$VERSION.zip"

UNIVERSAL=1 VERSION="$VERSION" BUILD_NUM="$BUILD_NUM" SIGN_IDENTITY="$IDENTITY" \
    scripts/make_app.sh release

lipo -archs Belfry.app/Contents/MacOS/Belfry

if [ "$SKIP_NOTARIZE" != "--skip-notarize" ]; then
    echo "› notarizing…"
    rm -f "$ZIP"
    ditto -c -k --keepParent Belfry.app "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple Belfry.app
fi

# Final artifact: the (stapled) app, zipped.
rm -f "$ZIP"
ditto -c -k --keepParent Belfry.app "$ZIP"

# Regenerate the Sparkle appcast (docs/appcast.xml — published by GitHub
# Pages at belfry.robgough.net/appcast.xml). EdDSA-signs the zip with the
# private key from the login keychain; commit + push docs/ to publish.
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

echo "› gatekeeper assessment:"
spctl --assess --type execute -vv Belfry.app || true
echo "✓ $ZIP (+ docs/appcast.xml regenerated)"

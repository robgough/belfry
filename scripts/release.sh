#!/usr/bin/env bash
# Build, sign, notarize and staple a distributable Belfry.app, producing
# Belfry-<version>.zip ready to attach to a GitHub release.
#
# Usage: scripts/release.sh <version> [--skip-notarize]
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

VERSION="${1:?usage: scripts/release.sh <version> [--skip-notarize]}"
SKIP_NOTARIZE="${2:-}"
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

echo "› gatekeeper assessment:"
spctl --assess --type execute -vv Belfry.app || true
echo "✓ $ZIP"

#!/usr/bin/env bash
# Wrap a released, stapled Belfry.app in a signed + notarized + stapled DMG
# with the usual "drag to Applications" layout — the friendlier first
# download. The zip stays the canonical asset (Sparkle and Homebrew use it).
#
# Usage: scripts/make_dmg.sh <version>
# Needs Belfry-<version>.zip here (as release.sh leaves it, or fetched from
# the GitHub release), plus the same signing/notary setup as release.sh:
# SIGN_IDENTITY (default "Developer ID Application"), and either
# NOTARY_KEY_FILE + NOTARY_KEY_ID + NOTARY_ISSUER (CI) or a notarytool
# keychain profile NOTARY_PROFILE (default belfry-notary).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: $0 <version>}"
ZIP="Belfry-$VERSION.zip"
DMG="Belfry-$VERSION.dmg"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

if [ ! -f "$ZIP" ]; then
    echo "› fetching $ZIP from the release"
    curl -fsSL -o "$ZIP" "https://github.com/robgough/belfry/releases/download/v$VERSION/$ZIP"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# ditto keeps the stapled ticket and the signature intact.
ditto -x -k "$ZIP" "$STAGE"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
echo "› building $DMG"
hdiutil create -volname "Belfry" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

echo "› signing"
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "› notarizing (a few minutes)"
if [ -n "${NOTARY_KEY_FILE:-}" ]; then
    NOTARY_AUTH=(--key "$NOTARY_KEY_FILE"
                 --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required with NOTARY_KEY_FILE}"
                 --issuer "${NOTARY_ISSUER:?NOTARY_ISSUER is required with NOTARY_KEY_FILE}")
else
    NOTARY_AUTH=(--keychain-profile "${NOTARY_PROFILE:-belfry-notary}")
fi
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple "$DMG"

echo "› verifying"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
xcrun stapler validate "$DMG"
echo "✓ $DMG"

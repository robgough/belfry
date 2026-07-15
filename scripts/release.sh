#!/usr/bin/env bash
# Build, sign, notarize and staple a distributable Belfry.app, producing
# Belfry-<version>.zip ready to attach to a GitHub release.
#
# Usage: scripts/release.sh [version] [--skip-notarize] [--skip-appcast]
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
#
# Headless (GitHub Actions) instead uses an App Store Connect API key, which
# needs no keychain profile — set NOTARY_KEY_FILE=<.p8> with NOTARY_KEY_ID and
# NOTARY_ISSUER. CI also passes --skip-appcast: the Sparkle EdDSA key is
# deliberately not on GitHub, so the appcast is signed and published from a
# machine you control (scripts/publish_appcast.sh). See RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=""
SKIP_NOTARIZE=""
SKIP_APPCAST=""
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE="--skip-notarize" ;;
        --skip-appcast) SKIP_APPCAST="1" ;;
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
    # A keychain profile needs a keychain (and, on a Mac, a GUI session to have
    # created it). CI has neither, so an App Store Connect API key is the
    # headless path — same notary service, file-based credentials.
    if [ -n "${NOTARY_KEY_FILE:-}" ]; then
        NOTARY_AUTH=(--key "$NOTARY_KEY_FILE"
                     --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required with NOTARY_KEY_FILE}"
                     --issuer "${NOTARY_ISSUER:?NOTARY_ISSUER is required with NOTARY_KEY_FILE}")
    else
        NOTARY_AUTH=(--keychain-profile "$PROFILE")
    fi
    xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
    xcrun stapler staple Belfry.app
fi

# Final artifact: the (stapled) app, zipped.
rm -f "$ZIP"
ditto -c -k --keepParent Belfry.app "$ZIP"

# Regenerate the Sparkle appcast (docs/appcast.xml — published by GitHub Pages
# at belfry.robgough.net/appcast.xml). publish_appcast.sh owns this so the
# EdDSA signing lives in exactly one place, local and CI alike.
if [ -n "$SKIP_APPCAST" ]; then
    APPCAST_NOTE="appcast NOT generated — run scripts/publish_appcast.sh $VERSION on a machine with the Sparkle key"
else
    scripts/publish_appcast.sh "$VERSION" --generate-only
    APPCAST_NOTE="docs/appcast.xml regenerated"
fi

echo "› gatekeeper assessment:"
spctl --assess --type execute -vv Belfry.app || true
echo "✓ $ZIP ($APPCAST_NOTE)"

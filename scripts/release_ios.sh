#!/usr/bin/env bash
# Archive the iOS/iPadOS app and upload it to App Store Connect, where it
# lands in TestFlight once Apple finishes processing.
#
# Usage: scripts/release_ios.sh [version] [--export-only]
#
#   --export-only   produce .build/ios/export/Belfry.ipa instead of uploading
#
# Version defaults to the next calendar release (YYYY.MM.N, N = nth release
# this month across both platforms), derived from existing v* tags — which
# is why releases must be tagged (see RELEASING.md).
#
# Signing is automatic (cloud-managed) for team 5Z5EG95CQL — the first run
# creates the Apple Distribution certificate and provisioning profile for
# you. That, and the upload, need App Store Connect credentials; either:
#   - be signed into the team's Apple ID in Xcode (Settings > Accounts), or
#   - set ASC_KEY_ID + ASC_ISSUER_ID for an App Store Connect API key, with
#     the .p8 at ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
#     (or point ASC_KEY_PATH at it).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=""
EXPORT_ONLY=""
for arg in "$@"; do
    case "$arg" in
        --export-only) EXPORT_ONLY="--export-only" ;;
        *) VERSION="$arg" ;;
    esac
done
if [ -z "$VERSION" ]; then
    YM="$(date +%Y.%m)"
    LAST="$(git tag --list "v$YM.*" | sed "s/^v$YM\.//" | sort -n | tail -1)"
    VERSION="$YM.$((${LAST:-0} + 1))"
    echo "› version $VERSION (next untagged $YM release)"
fi
TEAM_ID="5Z5EG95CQL"
# Same build-number scheme as the macOS release: commit count, so commit
# before building — App Store Connect requires each upload to increase it.
BUILD_NUM="$(git rev-list --count HEAD)"

# xcodebuild needs full Xcode, not the CommandLineTools shim.
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
    for XC in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [ -d "$XC" ]; then
            export DEVELOPER_DIR="$XC/Contents/Developer"
            break
        fi
    done
fi

# API-key auth (skipped when unset — xcodebuild then uses Xcode's accounts).
AUTH_ARGS=()
if [ -n "${ASC_KEY_ID:-}" ]; then
    AUTH_ARGS=(
        -authenticationKeyID "$ASC_KEY_ID"
        -authenticationKeyIssuerID "${ASC_ISSUER_ID:?ASC_ISSUER_ID must be set alongside ASC_KEY_ID}"
        -authenticationKeyPath "${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
    )
fi

xcodegen generate

ARCHIVE=".build/ios/Belfry-$VERSION.xcarchive"
rm -rf "$ARCHIVE"

echo "› archiving $VERSION ($BUILD_NUM)…"
xcodebuild archive \
    -project BelfryiOS.xcodeproj -scheme BelfryiOS \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUM"

DEST="upload"
[ "$EXPORT_ONLY" = "--export-only" ] && DEST="export"

# manageAppVersionAndBuildNumber off: we set the build number ourselves.
PLIST=".build/ios/ExportOptions.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$DEST</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF

echo "› exporting ($DEST)…"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$PLIST" \
    -exportPath .build/ios/export \
    -allowProvisioningUpdates ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}

if [ "$DEST" = "upload" ]; then
    echo "✓ uploaded $VERSION ($BUILD_NUM) — it appears in TestFlight once processing finishes (~minutes; watch App Store Connect or the confirmation email)"
else
    echo "✓ exported: .build/ios/export/Belfry.ipa ($VERSION, build $BUILD_NUM)"
fi

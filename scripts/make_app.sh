#!/usr/bin/env bash
# Assemble Belfry.app from the SPM build output + icon + Info.plist.
# Usage: scripts/make_app.sh [debug|release]
# Env:   VERSION=0.2.0       marketing version (CFBundleShortVersionString)
#        BUILD_NUM=42        build number (CFBundleVersion)
#        UNIVERSAL=1         build arm64 + x86_64 instead of the native arch
#        SIGN_IDENTITY=<id>  codesign identity; default "-" (ad-hoc). A real
#                            identity also turns on hardened runtime + timestamp
#                            (required for notarization).
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
CONFIG="${1:-debug}"
VERSION="${VERSION:-0.1}"
BUILD_NUM="${BUILD_NUM:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ARCH_FLAGS=()
[ "${UNIVERSAL:-0}" = "1" ] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

echo "› building ($CONFIG${UNIVERSAL:+, universal})…"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} >/dev/null
BINDIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
BIN="$BINDIR/Belfry"
ASKPASS="$BINDIR/belfry-askpass"
[ -x "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }
[ -x "$ASKPASS" ] || { echo "✗ askpass helper not found at $ASKPASS"; exit 1; }

APP="Belfry.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Belfry"
# Sibling of the main binary so SSHControl.askpassEnvironment() finds it.
cp "$ASKPASS" "$APP/Contents/MacOS/belfry-askpass"
cp Resources/Belfry.icns "$APP/Contents/Resources/Belfry.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Belfry</string>
    <key>CFBundleDisplayName</key><string>Belfry</string>
    <key>CFBundleExecutable</key><string>Belfry</string>
    <key>CFBundleIdentifier</key><string>net.robgough.belfry</string>
    <key>CFBundleIconFile</key><string>Belfry</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUM}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Sign the nested helper first, then the app, so both are valid. Ad-hoc by
# default (locally built, no notarization needed); a real identity gets the
# hardened runtime + secure timestamp notarization requires.
SIGN_ARGS=(--force -s "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/belfry-askpass"
codesign "${SIGN_ARGS[@]}" "$APP"
touch "$APP"
echo "✓ built $APP ($VERSION ($BUILD_NUM), signed: $SIGN_IDENTITY)"

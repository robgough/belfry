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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Belfry"
# Sibling of the main binary so SSHControl.askpassEnvironment() finds it.
cp "$ASKPASS" "$APP/Contents/MacOS/belfry-askpass"
cp Resources/Belfry.icns "$APP/Contents/Resources/Belfry.icns"

# Embed Sparkle.framework (SPM links it via @rpath but doesn't bundle it).
SPARKLE_FW="$(find .build/artifacts -type d -path "*/macos-*/Sparkle.framework" | head -1)"
[ -n "$SPARKLE_FW" ] || { echo "✗ Sparkle.framework not found under .build/artifacts"; exit 1; }
ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
# Point the binary at the bundled copy, and strip build-machine rpaths.
otool -l "$APP/Contents/MacOS/Belfry" | awk '/LC_RPATH/{getline; getline; print $2}' \
    | grep -E "^/" | grep -Ev "^/(usr|System)/" | while read -r rp; do
        install_name_tool -delete_rpath "$rp" "$APP/Contents/MacOS/Belfry" 2>/dev/null || true
    done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Belfry"

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
    <key>SUFeedURL</key><string>https://belfry.robgough.net/appcast.xml</string>
    <key>SUPublicEDKey</key><string>nKdcgJBzUX/UsPNA71RLRx1CzXBby33QOor7CQ7t9Yg=</string>
</dict>
</plist>
PLIST

# Sign inside-out so every nested code is valid before its container. Ad-hoc
# by default (locally built, no notarization needed); a real identity gets the
# hardened runtime + secure timestamp notarization requires. Sparkle's nested
# executables are signed per the Sparkle docs — Downloader.xpc keeps its
# sandbox entitlements.
SIGN_ARGS=(--force -s "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
FW="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGN_ARGS[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGN_ARGS[@]}" "$FW/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$FW/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" "$FW"
codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/belfry-askpass"
codesign "${SIGN_ARGS[@]}" "$APP"
touch "$APP"
echo "✓ built $APP ($VERSION ($BUILD_NUM), signed: $SIGN_IDENTITY)"

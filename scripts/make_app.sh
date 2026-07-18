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

# Prefer a *released* Xcode over a beta: a shipped build shouldn't carry a beta
# SDK, which is the same reason RELEASING.md gives for iOS, and release_ios.sh
# already picks in this order. hailmary has only the beta installed, so it still
# lands there (hence the macOS 27 SDK warning) — but the moment a release Xcode
# is installed, or DEVELOPER_DIR is set (CI does), that wins.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    for XC in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        [ -d "$XC" ] && { export DEVELOPER_DIR="$XC/Contents/Developer"; break; }
    done
fi
CONFIG="${1:-debug}"
VERSION="${VERSION:-0.1}"
BUILD_NUM="${BUILD_NUM:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
# Deployment target for cross-built slices; matches Package.swift's .macOS(.v14).
MACOS_MIN="14.0"

# Quiet on success, but say everything on failure. SwiftPM reports plenty on
# stdout, so `>/dev/null` didn't just hide progress: a failed CI build printed
# "› building (release, universal)…" then exit 1 and nothing else, with the
# reason discarded at the source rather than merely unread.
build() {  # build <extra swift build args…>
    local log; log="$(mktemp -t belfry-build)"
    if ! swift build -c "$CONFIG" "$@" >"$log" 2>&1; then
        echo "✗ swift build ${*:-} failed:" >&2
        cat "$log" >&2
        rm -f "$log"
        exit 1
    fi
    rm -f "$log"
}

if [ "${UNIVERSAL:-0}" = "1" ]; then
    # Build each slice on its own and lipo them, rather than the one-shot
    # `swift build --arch arm64 --arch x86_64`. --arch routes SwiftPM through
    # XCBuild, and XCBuild wants the Metal *toolchain component* to compile
    # SwiftTerm's Shaders.metal — which a stock runner hasn't got, and can't
    # install for an Xcode its OS didn't ship with. A plain `swift build` never
    # goes near XCBuild: it invokes `xcrun metal`, which works anywhere Xcode
    # does, and is why `swift test` passed on every runner this failed on.
    # (--arch also trips swift-package-manager#7958 on some SwiftPM versions.
    # This dodges both, on any toolchain.)
    echo "› building ($CONFIG, universal — one pass per slice)…"
    STAGE="$(mktemp -d -t belfry-slices)"
    trap 'rm -rf "$STAGE"' EXIT
    for ARCH in arm64 x86_64; do
        echo "  · $ARCH"
        build --triple "$ARCH-apple-macosx$MACOS_MIN"
        SLICE_BIN="$(swift build -c "$CONFIG" --triple "$ARCH-apple-macosx$MACOS_MIN" --show-bin-path)"
        # Copy each slice out before the next pass: with some build systems both
        # triples resolve to the same bin path, so the second would clobber it.
        cp "$SLICE_BIN/Belfry" "$STAGE/Belfry.$ARCH"
        cp "$SLICE_BIN/belfry-askpass" "$STAGE/belfry-askpass.$ARCH"
    done
    BINDIR="$STAGE"
    lipo -create "$STAGE/Belfry.arm64" "$STAGE/Belfry.x86_64" -output "$STAGE/Belfry"
    lipo -create "$STAGE/belfry-askpass.arm64" "$STAGE/belfry-askpass.x86_64" \
         -output "$STAGE/belfry-askpass"
else
    echo "› building ($CONFIG)…"
    build
    BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"
fi
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

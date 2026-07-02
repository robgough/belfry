#!/usr/bin/env bash
# Assemble Belfry.app from the SPM build output + icon + Info.plist.
# Usage: scripts/make_app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
CONFIG="${1:-debug}"

echo "› building ($CONFIG)…"
swift build -c "$CONFIG" >/dev/null
BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"
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

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so it launches cleanly (locally built, no notarization needed).
# Sign the nested helper first, then the app (deep) so both are valid.
codesign --force -s - "$APP/Contents/MacOS/belfry-askpass" >/dev/null 2>&1 || true
codesign --force -s - "$APP" >/dev/null 2>&1 || true
touch "$APP"
echo "✓ built $APP"

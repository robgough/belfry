#!/usr/bin/env bash
# One-time: copy Belfry's Sparkle EdDSA private key from the login keychain
# into the SPARKLE_ED_PRIVATE_KEY secret on the `release` environment, so the
# macOS release workflow can sign and publish the appcast itself.
#
# Run from Terminal.app (the keychain needs the GUI session — not over ssh or
# inside a Belfry/tmux session). The key only ever touches a temp file that is
# deleted straight after the upload.
set -euo pipefail
cd "$(dirname "$0")/.."

SPARKLE_BIN=".build/sparkle-tools/bin"
if [ ! -x "$SPARKLE_BIN/generate_keys" ]; then
    echo "› fetching Sparkle tools…"
    mkdir -p .build/sparkle-tools
    curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz" \
        | tar -xJ -C .build/sparkle-tools
fi

TMP="$(mktemp -t belfry-sparkle-key)"
trap 'rm -f "$TMP"' EXIT
"$SPARKLE_BIN/generate_keys" -x "$TMP" >/dev/null
[ -s "$TMP" ] || { echo "✗ couldn't export the key (is it in this login keychain?)" >&2; exit 1; }
gh secret set SPARKLE_ED_PRIVATE_KEY --env release --repo robgough/belfry < "$TMP"
echo "✓ SPARKLE_ED_PRIVATE_KEY set on the release environment — releases now publish the appcast themselves"

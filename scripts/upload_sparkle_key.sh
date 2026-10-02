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

# Fail loudly: any error says which step broke (the first version exited
# silently under `set -e`).
trap 'echo "✗ failed at line $LINENO — nothing was uploaded" >&2' ERR

# generate_keys -x refuses to overwrite an existing file, so export into a
# fresh path inside a private temp directory (not a pre-created temp file).
DIR="$(mktemp -d -t belfry-sparkle)"
trap 'rm -rf "$DIR"' EXIT
KEY="$DIR/sparkle_ed.key"

echo "› exporting the Sparkle key from your login keychain (allow access if macOS asks)…"
"$SPARKLE_BIN/generate_keys" -x "$KEY"
[ -s "$KEY" ] || { echo "✗ no key was exported — is Belfry's Sparkle key in this login keychain?" >&2; exit 1; }

echo "› uploading it as SPARKLE_ED_PRIVATE_KEY on the release environment…"
gh secret set SPARKLE_ED_PRIVATE_KEY --env release --repo robgough/belfry < "$KEY"
echo "✓ done — releases now publish the Sparkle appcast themselves"

#!/usr/bin/env bash
# Upload the secrets .github/workflows/release-macos.yml needs, and optionally
# create the `release` environment that gates it.
#
# Usage: scripts/upload_ci_secrets.sh [--check]
#
#   --check   list what's set (names only — GitHub never reveals values) and
#             re-run the connectivity checks, uploading nothing.
#
# Run this from Terminal.app. gh reads its token from the login keychain, which
# only the GUI (Aqua) security session can unlock — over ssh, or from a terminal
# Belfry is hosting, gh reports "token is invalid" when it simply can't read it.
#
# Handling: values are read with the terminal echo off, so nothing reaches your
# shell history; they're piped to gh on stdin rather than passed as arguments,
# so nothing shows up in `ps`; temp files are 0600 inside a private directory
# that's shredded on exit, including on Ctrl-C.
#
# Deliberately NOT here: the Sparkle EdDSA key. CI must not be able to sign an
# auto-update — see RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${BELFRY_REPO:-robgough/belfry}"
TAP_REPO="${BELFRY_TAP_REPO:-robgough/homebrew-belfry}"
CHECK_ONLY=""
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

TMP="$(mktemp -d)"
chmod 700 "$TMP"
cleanup() {
    # Overwrite before unlinking: cheap insurance for key material.
    find "$TMP" -type f -exec dd if=/dev/zero of={} bs=1k count=8 conv=notrunc status=none \; 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
note() { printf '    %s\n' "$*"; }

# ── preflight ────────────────────────────────────────────────────────────────
command -v gh >/dev/null || { bad "gh not found (brew install gh)"; exit 1; }
if ! gh auth status >/dev/null 2>&1; then
    bad "gh isn't authenticated for this session."
    note "If you're over ssh or in a Belfry-hosted terminal, that's expected:"
    note "gh's token is in the login keychain and needs the GUI session."
    note "Re-run this from Terminal.app, or: gh auth login"
    exit 1
fi
gh repo view "$REPO" >/dev/null 2>&1 || { bad "can't see $REPO with this gh login"; exit 1; }
ok "gh authenticated; $REPO reachable"

if [ -n "$CHECK_ONLY" ]; then
    say "Secrets currently set on $REPO"
    gh secret list -R "$REPO" || true
    say "Environments"
    gh api "repos/$REPO/environments" --jq '.environments[].name' 2>/dev/null || note "(none)"
    exit 0
fi

say "This uploads 6 secrets to $REPO. Nothing is echoed or stored locally."

# ── 1. Developer ID certificate + private key ────────────────────────────────
say "1/4  Developer ID Application certificate (.p12)"
note "Keychain Access → login → My Certificates → the 'Developer ID Application:"
note "Rob Gough (5Z5EG95CQL)' row → right-click → Export → .p12, with a password."
note "Expand the row first: exporting the *certificate* alone omits the private"
note "key, and signing in CI then fails in a way that's tedious to diagnose."
printf '  path to .p12: '
read -r P12_PATH
P12_PATH="${P12_PATH/#\~/$HOME}"
[ -f "$P12_PATH" ] || { bad "no such file: $P12_PATH"; exit 1; }
printf '  .p12 password (not echoed): '
read -rs P12_PASS; echo
[ -n "$P12_PASS" ] || { bad "an empty password won't import in CI"; exit 1; }

# Validate before uploading. Note the plain string rather than an array:
# macOS ships bash 3.2, where expanding an *empty* array under `set -u` is an
# error — which silently emptied openssl's output and made this script blame a
# perfectly good .p12. Unquoted, an empty $P12_LEGACY simply disappears.
P12_LEGACY=""
p12_dump() { openssl pkcs12 $P12_LEGACY -in "$P12_PATH" -passin "pass:$P12_PASS" "$@" 2>/dev/null; }

# Can we open it at all? openssl 3 needs -legacy for Keychain's RC2-era PKCS#12.
if p12_dump -nokeys -noout; then
    ok "opened"
elif P12_LEGACY="-legacy"; p12_dump -nokeys -noout; then
    ok "opened (legacy PKCS#12 encryption)"
else
    P12_LEGACY=""
    bad "couldn't open that .p12 — wrong password, or not a PKCS#12 file"
    exit 1
fi

# Every check below distinguishes "openssl failed" from "the thing isn't there".
# Conflating them is how this script told Rob he'd exported the wrong thing when
# he hadn't; an empty result must never be read as a diagnosis on its own.
if ! p12_dump -nocerts -nodes > "$TMP/key.pem"; then
    bad "openssl couldn't read the key section of that .p12 (unexpected)"
    note "Try: openssl pkcs12 $P12_LEGACY -in '$P12_PATH' -nocerts -nodes"
    exit 1
fi
if grep -q "PRIVATE KEY" "$TMP/key.pem"; then
    ok "private key present"
else
    bad "no private key in that .p12 — the certificate was exported on its own"
    note "In Keychain Access, expand the certificate row (▸) and export the"
    note "identity underneath it, not the certificate above."
    exit 1
fi
# -print_certs walks the whole chain; a Keychain export carries intermediates,
# and `openssl x509` would only ever read the first one.
if ! p12_dump -nokeys > "$TMP/certs.pem"; then
    bad "openssl couldn't read the certificates from that .p12 (unexpected)"
    exit 1
fi
SUBJECTS="$(openssl crl2pkcs7 -nocrl -certfile "$TMP/certs.pem" 2>/dev/null \
    | openssl pkcs7 -print_certs -noout 2>/dev/null || true)"
case "$SUBJECTS" in
    *"Developer ID Application"*) ok "contains a Developer ID Application certificate" ;;
    *) bad "no Developer ID Application cert in that .p12"
       note "An 'Apple Development' certificate can't sign a release build."
       # subject= lines only: -print_certs also emits issuer=, which would
       # double every entry in this list.
       note "Found: $(printf '%s' "$SUBJECTS" | sed -n 's/^subject=[ /]*//p' \
             | cut -d/ -f1 | sort -u | paste -sd'; ' - || echo nothing)"
       exit 1 ;;
esac
EXPIRY="$(openssl x509 -in "$TMP/certs.pem" -noout -enddate 2>/dev/null | cut -d= -f2)"
ok "expires: ${EXPIRY:-unknown}"

base64 -i "$P12_PATH" > "$TMP/p12.b64"
gh secret set MACOS_CERT_P12_BASE64 -R "$REPO" < "$TMP/p12.b64"
printf '%s' "$P12_PASS" | gh secret set MACOS_CERT_PASSWORD -R "$REPO"
unset P12_PASS
ok "MACOS_CERT_P12_BASE64, MACOS_CERT_PASSWORD"

# ── 2. App Store Connect API key (notarization) ──────────────────────────────
say "2/4  App Store Connect API key (.p8) — how CI notarizes headlessly"
note "App Store Connect → Users and Access → Integrations → App Store Connect API"
note "→ + → role 'Developer'. The .p8 downloads once and cannot be re-downloaded."
printf '  path to .p8: '
read -r P8_PATH
P8_PATH="${P8_PATH/#\~/$HOME}"
[ -f "$P8_PATH" ] || { bad "no such file: $P8_PATH"; exit 1; }
grep -q "BEGIN PRIVATE KEY" "$P8_PATH" || { bad "that doesn't look like a .p8 private key"; exit 1; }
ok "looks like a private key"

# The filename is AuthKey_<KEYID>.p8 — offer it rather than make you retype it.
SUGGESTED_ID="$(basename "$P8_PATH" | sed -nE 's/^AuthKey_([A-Z0-9]+)\.p8$/\1/p')"
if [ -n "$SUGGESTED_ID" ]; then
    printf '  key ID [%s]: ' "$SUGGESTED_ID"
else
    printf '  key ID: '
fi
read -r ASC_KEY_ID
ASC_KEY_ID="${ASC_KEY_ID:-$SUGGESTED_ID}"
[ -n "$ASC_KEY_ID" ] || { bad "key ID is required"; exit 1; }
printf '  issuer ID (UUID, same page): '
read -r ASC_ISSUER_ID
case "$ASC_ISSUER_ID" in
    ????????-????-????-????-????????????) ok "issuer looks like a UUID" ;;
    *) bad "issuer '$ASC_ISSUER_ID' isn't a UUID — check Integrations → Issuer ID"; exit 1 ;;
esac

base64 -i "$P8_PATH" > "$TMP/p8.b64"
gh secret set ASC_KEY_P8_BASE64 -R "$REPO" < "$TMP/p8.b64"
printf '%s' "$ASC_KEY_ID"    | gh secret set ASC_KEY_ID -R "$REPO"
printf '%s' "$ASC_ISSUER_ID" | gh secret set ASC_ISSUER_ID -R "$REPO"
ok "ASC_KEY_P8_BASE64, ASC_KEY_ID, ASC_ISSUER_ID"

# ── 3. Tap token (cask bump) ─────────────────────────────────────────────────
say "3/4  Tap push token — for the Homebrew cask bump"
note "github.com/settings/personal-access-tokens/new → fine-grained →"
note "Repository access: only $TAP_REPO → Permissions → Contents: Read and write."
note "Scope it to that repo alone: it does not need access to $REPO."
printf '  token (not echoed): '
read -rs TAP_TOKEN; echo
[ -n "$TAP_TOKEN" ] || { bad "token is required"; exit 1; }

# Verify it can actually push to the tap — a mis-scoped PAT otherwise fails at
# the very end of a release, after notarization has already burned 20 minutes.
PERMS="$(curl -sf -H "Authorization: Bearer $TAP_TOKEN" \
    "https://api.github.com/repos/$TAP_REPO" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["permissions"]["push"])' 2>/dev/null || true)"
case "$PERMS" in
    True) ok "token has push access to $TAP_REPO" ;;
    False) bad "token can read $TAP_REPO but not push — needs Contents: Read and write"; exit 1 ;;
    *) bad "token can't see $TAP_REPO — wrong repo selected, or expired"; exit 1 ;;
esac
printf '%s' "$TAP_TOKEN" | gh secret set TAP_PUSH_TOKEN -R "$REPO"
unset TAP_TOKEN
ok "TAP_PUSH_TOKEN"

# ── 4. release environment ───────────────────────────────────────────────────
say "4/4  'release' environment (required reviewer)"
note "The workflow targets this environment. With you as a required reviewer, a"
note "run pauses for approval before it can use the signing identity."
printf '  create it with you as required reviewer? [Y/n]: '
read -r ANS
case "${ANS:-y}" in
    [Yy]*)
        USER_ID="$(gh api user --jq .id)"
        if gh api -X PUT "repos/$REPO/environments/release" \
             --input - >/dev/null 2>&1 <<EOF
{"reviewers":[{"type":"User","id":$USER_ID}],"deployment_branch_policy":null}
EOF
        then ok "environment 'release' created, you are a required reviewer"
        else bad "couldn't create it (needs admin on $REPO) — add it by hand:"
             note "Settings → Environments → New environment → 'release' → required reviewers"
        fi
        ;;
    *) note "skipped — the workflow still runs, just without the approval gate" ;;
esac

say "Done"
gh secret list -R "$REPO"
cat <<'EOF'

Next: Actions → Release (macOS) → Run workflow, with dry_run ticked.
That builds, signs and notarizes without tagging or publishing — worth doing
first, since CI builds with the runner's Xcode and this Mac only has Xcode-beta.
EOF

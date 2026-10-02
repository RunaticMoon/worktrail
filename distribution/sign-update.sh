#!/bin/bash
# Sign only an already verified release. No Keychain fallback; secret goes via stdin.
set -euo pipefail
: "${RELEASE_TAG:?}" "${WORKLOG_SPARKLE_PRIVATE_KEY:?}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
python3 distribution/release.py verify "$RELEASE_TAG" release

# Validate the secret before passing it to tools (some print invalid inputs in errors).
python3 - <<'PY'
import base64, os, sys
try:
    secret = base64.b64decode(os.environ['WORKLOG_SPARKLE_PRIVATE_KEY'], validate=True)
    if len(secret) != 32:
        raise ValueError()
except Exception:
    sys.exit('The dedicated update key does not match the committed public key')
PY
swift distribution/validate-update-key.swift distribution/sparkle-public-key.txt

# The preceding CI step resolves the pinned binary without the signing secret.
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$SIGN_UPDATE" ]] || { echo 'Sparkle signing tool is missing' >&2; exit 1; }
DMG="$ROOT/release/WorkLog-${RELEASE_TAG#v}-arm64.dmg"
SIGNATURE="$(printf '%s\n' "$WORKLOG_SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - -p "$DMG")"
printf '%s\n' "$WORKLOG_SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - --verify "$DMG" "$SIGNATURE"
python3 distribution/release.py appcast "$RELEASE_TAG" release "$SIGNATURE"
printf '%s\n' "$WORKLOG_SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - -p release/appcast.xml
printf '%s\n' "$WORKLOG_SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - --verify release/appcast.xml
python3 distribution/release.py verify-appcast "$RELEASE_TAG" release

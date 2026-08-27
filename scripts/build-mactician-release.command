#!/bin/zsh
set -euo pipefail

readonly PROJECT_DIR="${0:A:h:h}"
readonly DEFAULT_APK_DIR="$PROJECT_DIR/private/tft-apks"
readonly NOTARY_PROFILE="${MACTICIAN_NOTARY_PROFILE:-mactician-notary}"

typeset signing_identity="${MACTICIAN_CODESIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    typeset -a developer_identities
    developer_identities=("${(@f)$(security find-identity -v -p codesigning \
        | awk -F'"' '/"Developer ID Application:/ { print $2 }')}")
    developer_identities=("${(@)developer_identities:#}")

    if (( ${#developer_identities} != 1 )); then
        print -u2 "Expected exactly one Developer ID Application identity; found ${#developer_identities}."
        print -u2 "Set MACTICIAN_CODESIGN_IDENTITY explicitly when more than one identity is installed."
        exit 2
    fi
    signing_identity="$developer_identities[1]"
fi

readonly SIGNING_IDENTITY="$signing_identity"
readonly APK_DIR="${TFT_GAME_APK_DIR:-$DEFAULT_APK_DIR}"

if [[ ! -d "$APK_DIR" ]]; then
    print -u2 "Pinned APK directory not found: $APK_DIR"
    exit 2
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null; then
    print -u2 "Notarization Keychain profile is unavailable or invalid: $NOTARY_PROFILE"
    exit 2
fi

export MACTICIAN_CODESIGN_IDENTITY="$SIGNING_IDENTITY"
export MACTICIAN_NOTARY_PROFILE="$NOTARY_PROFILE"
export TFT_GAME_APK_DIR="$APK_DIR"

exec "$PROJECT_DIR/scripts/build-mactician.command"

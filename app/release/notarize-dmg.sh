#!/bin/bash
# Takes a signed DMG through Apple notarization: submit, wait, staple, and
# verify the result actually satisfies Gatekeeper.
#
# Usage: app/release/notarize-dmg.sh [path-to-dmg]
#   If no path is given, defaults to app/build/VPNSwitch-<version>.dmg,
#   where <version> is read back OUT of the built app/build/VPNSwitch.app
#   bundle via app/release/read-app-version.sh — the same source of truth
#   app/release/make-dmg.sh uses for its own DMG filename, never the
#   repo's Info.plist source directly, so this script can never target a
#   DMG that make-dmg.sh wouldn't have produced for the currently-built
#   app.
#
# Output: the same DMG file, now notarized and stapled, on success.
#
# Requires the DMG to already be signed with a Developer ID identity (see
# app/release/make-dmg.sh) — an ad-hoc-signed DMG can never be notarized.
#
# WHY THIS MATTERS: UpdateInstaller's verification
# (app/VPNSwitch/Sources/VPNSwitch/UpdateInstaller.swift) requires
#   spctl -a -t open --context context:primary-signature
# to exit 0 before installing a downloaded update. That check passes ONLY
# for a notarized artifact — Developer ID signing alone is not enough.
# This script is what makes that guarantee hold for real, and it also
# stops Gatekeeper warning every person who downloads the DMG.
#
# CREDENTIALS: never printed, copied, or logged by this script. Resolved
# in this order:
#   1. NOTARY_PROFILE env var (default "VPNSwitchNotary") — a keychain
#      profile created once via `xcrun notarytool store-credentials`, used
#      via `--keychain-profile`.
#   2. NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER env vars — an App Store
#      Connect API key path, key ID, and issuer ID, used via `--key`,
#      `--key-id`, `--issuer`. For a contributor without a stored profile.
#   3. Neither available: fail with setup instructions (see
#      credentials_missing() below) rather than a raw notarytool error.
#
# This is a real network round trip against Apple and can take several
# minutes. Deliberately does not impose an aggressive timeout on top of
# `notarytool submit --wait` — an impatient timeout would abort a
# legitimate, slow-but-successful submission.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${APP_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/VPNSwitch.app"

credentials_missing() {
    echo "error: no notarization credentials configured." >&2
    echo "" >&2
    echo "This script needs an App Store Connect API key to submit to Apple's" >&2
    echo "notarization service. Set it up ONE of these two ways:" >&2
    echo "" >&2
    echo "  1. (Preferred) Store a keychain profile once:" >&2
    echo "       xcrun notarytool store-credentials \"VPNSwitchNotary\" \\" >&2
    echo "           --key <path-to-AuthKey_XXXX.p8> \\" >&2
    echo "           --key-id <key-id> --issuer <issuer-id>" >&2
    echo "     The key ID and issuer ID come from App Store Connect ->" >&2
    echo "     Users and Access -> Integrations -> App Store Connect API." >&2
    echo "     Verify with:" >&2
    echo "       xcrun notarytool history --keychain-profile \"VPNSwitchNotary\"" >&2
    echo "     Then rerun this script (it uses the profile named" >&2
    echo "     \"VPNSwitchNotary\" by default, or set NOTARY_PROFILE to match" >&2
    echo "     a differently-named profile)." >&2
    echo "" >&2
    echo "     If you already have a stored profile from another project" >&2
    echo "     (e.g. \"GateOpenerNotary\") using the same Apple Developer" >&2
    echo "     account, you can reuse it instead of creating a new one:" >&2
    echo "       export NOTARY_PROFILE=GateOpenerNotary" >&2
    echo "" >&2
    echo "  2. (No stored profile) Set these env vars for this invocation:" >&2
    echo "       NOTARY_KEY=<path-to-AuthKey_XXXX.p8>" >&2
    echo "       NOTARY_KEY_ID=<key-id>" >&2
    echo "       NOTARY_ISSUER=<issuer-id>" >&2
    echo "" >&2
    exit 1
}

# --- Resolve the DMG path ---------------------------------------------

if [ "$#" -ge 1 ]; then
    DMG_PATH="$1"
else
    if [ ! -d "${APP_BUNDLE}" ]; then
        echo "error: no DMG path given and ${APP_BUNDLE} not found to derive the default from." >&2
        echo "       Either pass a DMG path explicitly, or run app/release/make-dmg.sh first." >&2
        exit 1
    fi
    SHORT_VERSION="$("${SCRIPT_DIR}/read-app-version.sh" "${APP_BUNDLE}" short)"
    if [ -z "${SHORT_VERSION}" ]; then
        echo "error: could not read version from ${APP_BUNDLE}" >&2
        exit 1
    fi
    DMG_PATH="${BUILD_DIR}/VPNSwitch-${SHORT_VERSION}.dmg"
fi

if [ ! -f "${DMG_PATH}" ]; then
    echo "error: DMG not found at ${DMG_PATH}. Run app/release/make-dmg.sh first, or pass an explicit path." >&2
    exit 1
fi

# --- Resolve credentials -----------------------------------------------

NOTARY_PROFILE="${NOTARY_PROFILE:-VPNSwitchNotary}"

NOTARY_AUTH_ARGS=()
if xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
    echo "==> Using keychain profile: ${NOTARY_PROFILE}"
    NOTARY_AUTH_ARGS=(--keychain-profile "${NOTARY_PROFILE}")
elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
    echo "==> Using API key credentials from NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER"
    NOTARY_AUTH_ARGS=(--key "${NOTARY_KEY}" --key-id "${NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER}")
else
    credentials_missing
fi

# --- Submit and wait -----------------------------------------------------

echo "==> Submitting ${DMG_PATH} for notarization (this can take several minutes)..."
SUBMIT_LOG="$(mktemp "${TMPDIR:-/tmp}/vpnswitch-notarize-submit.XXXXXX")"
trap 'rm -f "${SUBMIT_LOG}"' EXIT

if ! xcrun notarytool submit "${DMG_PATH}" "${NOTARY_AUTH_ARGS[@]}" --wait 2>&1 | tee "${SUBMIT_LOG}"; then
    echo "error: notarytool submit failed to run. See output above." >&2
    exit 1
fi

SUBMISSION_ID="$(sed -n 's/^[[:space:]]*id: \(.*\)$/\1/p' "${SUBMIT_LOG}" | head -1)"
STATUS="$(sed -n 's/^[[:space:]]*status: \(.*\)$/\1/p' "${SUBMIT_LOG}" | tail -1)"

echo "==> Submission id: ${SUBMISSION_ID:-<unknown>}"
echo "==> Notarization status: ${STATUS:-<unknown>}"

if [ "${STATUS}" != "Accepted" ]; then
    echo "error: notarization did not succeed (status: ${STATUS:-<unknown>})." >&2
    if [ -n "${SUBMISSION_ID}" ]; then
        echo "==> Fetching notarization log for submission ${SUBMISSION_ID}..." >&2
        xcrun notarytool log "${SUBMISSION_ID}" "${NOTARY_AUTH_ARGS[@]}" >&2 || \
            echo "error: could not fetch notarization log either." >&2
    fi
    exit 1
fi

# --- Staple and validate -------------------------------------------------

echo "==> Stapling notarization ticket to ${DMG_PATH}..."
xcrun stapler staple "${DMG_PATH}"

echo "==> Validating staple..."
xcrun stapler validate "${DMG_PATH}"

# --- The acceptance check --------------------------------------------
# This is exactly what UpdateInstaller runs before installing a downloaded
# update. If this does not exit 0, the release is not shippable no matter
# what notarytool/stapler reported above.

echo "==> Running Gatekeeper acceptance check (spctl)..."
SPCTL_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/vpnswitch-notarize-spctl.XXXXXX")"
if ! spctl -a -t open --context context:primary-signature "${DMG_PATH}" > "${SPCTL_OUTPUT}" 2>&1; then
    echo "error: spctl rejected the notarized DMG. This release is NOT shippable." >&2
    echo "----- spctl output -----" >&2
    cat "${SPCTL_OUTPUT}" >&2
    echo "-------------------------" >&2
    rm -f "${SPCTL_OUTPUT}"
    exit 1
fi
cat "${SPCTL_OUTPUT}"
rm -f "${SPCTL_OUTPUT}"

echo "==> Done: ${DMG_PATH} is notarized, stapled, and passes Gatekeeper."

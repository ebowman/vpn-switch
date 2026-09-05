#!/bin/bash
# app/build.sh -- builds VPNSwitch (SwiftPM executable) in release mode and
# assembles it into a runnable .app bundle at app/build/VPNSwitch.app,
# ad-hoc codesigned.
#
# Usage:
#   app/build.sh
#
# Output:
#   app/build/VPNSwitch.app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="${SCRIPT_DIR}/VPNSwitch"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_DIR="${BUILD_DIR}/VPNSwitch.app"

echo "==> swift build (release)"
( cd "${PKG_DIR}" && swift build -c release )

BIN_PATH="${PKG_DIR}/.build/release/VPNSwitch"
if [ ! -x "${BIN_PATH}" ]; then
    echo "build.sh: expected binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> assembling app bundle at ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/VPNSwitch"
cp "${PKG_DIR}/Info.plist" "${APP_DIR}/Contents/Info.plist"

# Prefer a STABLE signing identity over ad-hoc. An ad-hoc signature
# (`--sign -`) derives the app's identity from its own hash, so it changes
# on EVERY rebuild and macOS treats each build as a different application
# — invalidating login-item registration, notification permission, and any
# TCC grant keyed on the app's identity, and re-prompting the operator
# after every rebuild. A Developer ID identity is keyed on identifier +
# team, so one grant survives all future rebuilds.
#
# Overridable via CODESIGN_IDENTITY (set to `-` to force ad-hoc);
# auto-detected otherwise; falls back to ad-hoc so contributors without an
# Apple certificate can still build.
# shellcheck source=release/lib/resolve-codesign-identity.sh
source "${SCRIPT_DIR}/release/lib/resolve-codesign-identity.sh"

if [ -n "${CODESIGN_IDENTITY}" ] && [ "${CODESIGN_IDENTITY}" != "-" ]; then
    echo "==> codesign with: ${CODESIGN_IDENTITY}"
    codesign --force --deep --sign "${CODESIGN_IDENTITY}" --timestamp --options runtime "${APP_DIR}"
else
    echo "==> ad-hoc codesign"
    echo "    NOTE: ad-hoc builds cannot be notarized or self-updated, and"
    echo "    the ad-hoc identity changes on every rebuild. Set"
    echo "    CODESIGN_IDENTITY, or install a Developer ID certificate, to stop that."
    codesign --force --deep -s - "${APP_DIR}"
fi

echo "==> done: ${APP_DIR}"

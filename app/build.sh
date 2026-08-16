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

echo "==> ad-hoc codesign"
codesign --force --deep -s - "${APP_DIR}"

echo "==> done: ${APP_DIR}"

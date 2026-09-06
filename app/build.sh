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

# --- bundle the control scripts (dns-config-8v7.3) --------------------------
# A self-update replaces only the .app; the scripts it drives live under
# ~/Library/Application Support/vpn-switch/{bin,lib,config} and would go
# stale otherwise. Ship a copy of them inside the bundle so the app can
# sync them into place on launch (see ScriptBundle.swift). This MUST happen
# before the codesign step below -- codesign is last, and Resources content
# added after signing would invalidate the signature.
SCRIPTS_RES_DIR="${APP_DIR}/Contents/Resources/vpn-switch"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> bundling control scripts into ${SCRIPTS_RES_DIR}"

VPN_CTL_SRC="${REPO_ROOT}/bin/vpn-ctl.sh"
# Only the EXAMPLE lan-hosts.conf is ever bundled (dns-config-c4r): the real,
# user-owned lan-hosts.conf is never shipped inside the app bundle, even if a
# real copy happens to exist in this checkout (see config/lan-hosts.conf in
# .gitignore). ScriptBundle.swift creates the installed lan-hosts.conf from
# this example only if the installed copy is absent, and never overwrites it.
LAN_HOSTS_CONF_EXAMPLE_SRC="${REPO_ROOT}/config/lan-hosts.conf.example"

if [ ! -f "${VPN_CTL_SRC}" ]; then
    echo "build.sh: missing ${VPN_CTL_SRC}" >&2
    exit 1
fi
if [ ! -f "${LAN_HOSTS_CONF_EXAMPLE_SRC}" ]; then
    echo "build.sh: missing ${LAN_HOSTS_CONF_EXAMPLE_SRC}" >&2
    exit 1
fi
if ! compgen -G "${REPO_ROOT}/lib/*.sh" > /dev/null; then
    echo "build.sh: no lib/*.sh files found under ${REPO_ROOT}/lib" >&2
    exit 1
fi

mkdir -p "${SCRIPTS_RES_DIR}/bin"
mkdir -p "${SCRIPTS_RES_DIR}/lib"
mkdir -p "${SCRIPTS_RES_DIR}/config"

cp "${VPN_CTL_SRC}" "${SCRIPTS_RES_DIR}/bin/vpn-ctl.sh"
cp "${REPO_ROOT}"/lib/*.sh "${SCRIPTS_RES_DIR}/lib/"
cp "${LAN_HOSTS_CONF_EXAMPLE_SRC}" "${SCRIPTS_RES_DIR}/config/lan-hosts.conf.example"

chmod 0755 "${SCRIPTS_RES_DIR}/bin/vpn-ctl.sh"
chmod 0755 "${SCRIPTS_RES_DIR}"/lib/*.sh

BUNDLE_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${PKG_DIR}/Info.plist")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${PKG_DIR}/Info.plist")"
echo "${BUNDLE_SHORT_VERSION}+${BUNDLE_VERSION}" > "${SCRIPTS_RES_DIR}/VERSION"

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

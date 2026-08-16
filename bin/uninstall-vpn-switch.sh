#!/bin/bash
# uninstall-vpn-switch.sh -- removes the VPN Switch app and installed control
# scripts. No sudo. Mirrors bin/install-vpn-switch.sh (dns-config-qsk.7).
#
# Usage:
#   bash bin/uninstall-vpn-switch.sh
#
# What this removes:
#   - /Applications/VPN Switch.app
#   - "$HOME/Library/Application Support/vpn-switch/bin"
#   - "$HOME/Library/Application Support/vpn-switch/lib"
#   - the login item registration (SMAppService), via the app binary's own
#     --unregister-login-item flag, run before the app is deleted
#   - the ie.boboco.vpnswitch UserDefaults domain (best-effort)
#
# What this deliberately LEAVES BEHIND (printed at the end):
#   - Any *.mobileconfig or *.env file under
#     "$HOME/Library/Application Support/vpn-switch/" (the IKEv2 profile and
#     Nord credentials live there too -- separate concern, never touched by
#     this script).
#
# Repo conventions: set -u, no set -e, case-guard BASH_SOURCE resolution,
# bash 3.2 compatible. No sudo.

set -u

case "${BASH_SOURCE[0]}" in
    */*) SCRIPT_PARENT="${BASH_SOURCE[0]%/*}" ;;
    *)   SCRIPT_PARENT="." ;;
esac
if ! REPO_ROOT="$(cd "${SCRIPT_PARENT}/.." 2>/dev/null && pwd)"; then
    echo "uninstall-vpn-switch: could not resolve repo root" >&2
    exit 1
fi
# REPO_ROOT is resolved for symmetry with install-vpn-switch.sh and possible
# future use, but this script does not read from the repo -- only from
# already-installed locations, so it works even if the repo checkout has
# moved or been deleted after install.
: "${REPO_ROOT}"

APP_DEST="/Applications/VPN Switch.app"
APP_BINARY="${APP_DEST}/Contents/MacOS/VPNSwitch"
INSTALL_ROOT="${HOME}/Library/Application Support/vpn-switch"
BIN_DIR="${INSTALL_ROOT}/bin"
LIB_DIR="${INSTALL_ROOT}/lib"
BUNDLE_ID="ie.boboco.vpnswitch"

echo "=== VPN Switch uninstall ==="
echo

# --- step 1: quit the app if running ---------------------------------------

echo "==> [1/5] Quitting app if running"
if pgrep -x VPNSwitch >/dev/null 2>&1; then
    pkill -x VPNSwitch 2>/dev/null
    _waited=0
    while pgrep -x VPNSwitch >/dev/null 2>&1 && [ "${_waited}" -lt 10 ]; do
        sleep 0.5
        _waited=$((_waited + 1))
    done
    if pgrep -x VPNSwitch >/dev/null 2>&1; then
        echo "    warning: VPNSwitch still running after wait" >&2
    else
        echo "    stopped"
    fi
else
    echo "    not running"
fi
echo

# --- step 2: unregister the login item --------------------------------------

echo "==> [2/5] Unregistering login item"
if [ -x "${APP_BINARY}" ]; then
    if "${APP_BINARY}" --unregister-login-item; then
        echo "    unregistered"
    else
        echo "    warning: --unregister-login-item exited non-zero (may already be unregistered)" >&2
    fi
else
    echo "    app binary not found at ${APP_BINARY} -- skipping (nothing to unregister via it)"
fi
echo

# --- step 3: remove the app --------------------------------------------------

echo "==> [3/5] Removing app"
if [ -d "${APP_DEST}" ]; then
    if rm -rf "${APP_DEST}"; then
        echo "    removed ${APP_DEST}"
    else
        echo "uninstall-vpn-switch: failed to remove ${APP_DEST}" >&2
        exit 1
    fi
else
    echo "    not present: ${APP_DEST}"
fi
echo

# --- step 4: remove installed scripts ---------------------------------------

echo "==> [4/5] Removing installed control scripts"
if [ -d "${BIN_DIR}" ]; then
    if rm -rf "${BIN_DIR}"; then
        echo "    removed ${BIN_DIR}"
    else
        echo "uninstall-vpn-switch: failed to remove ${BIN_DIR}" >&2
        exit 1
    fi
else
    echo "    not present: ${BIN_DIR}"
fi
if [ -d "${LIB_DIR}" ]; then
    if rm -rf "${LIB_DIR}"; then
        echo "    removed ${LIB_DIR}"
    else
        echo "uninstall-vpn-switch: failed to remove ${LIB_DIR}" >&2
        exit 1
    fi
else
    echo "    not present: ${LIB_DIR}"
fi
echo

# --- step 5: remove UserDefaults domain -------------------------------------

echo "==> [5/5] Removing UserDefaults domain ${BUNDLE_ID} (best-effort)"
if defaults delete "${BUNDLE_ID}" >/dev/null 2>&1; then
    echo "    removed"
else
    echo "    not present or already removed"
fi
echo

echo "=== Uninstall complete ==="
echo
echo "Left behind on purpose (NOT removed):"
if [ -d "${INSTALL_ROOT}" ]; then
    _left_any=0
    for _f in "${INSTALL_ROOT}"/*.mobileconfig "${INSTALL_ROOT}"/*.env; do
        [ -e "${_f}" ] || continue
        echo "  ${_f}"
        _left_any=1
    done
    if [ "${_left_any}" = "0" ]; then
        echo "  (none found under ${INSTALL_ROOT} -- directory itself left in place if non-empty)"
    fi
    echo "  directory: ${INSTALL_ROOT} (IKEv2 profile / credentials live here -- separate concern)"
else
    echo "  (${INSTALL_ROOT} does not exist)"
fi

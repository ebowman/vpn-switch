#!/bin/bash
# install-vpn-switch.sh -- builds the VPN Switch menu bar app and installs
# it plus the control scripts it drives, with NO sudo by default
# (dns-config-qsk.7 DESIGN ADJUSTMENT).
#
# Usage:
#   bash bin/install-vpn-switch.sh
#   INSTALL_PREFIX=/usr/local bash bin/install-vpn-switch.sh   # opt-in, see below
#
# What this installs (default, no sudo):
#   - app/build/VPNSwitch.app                    -> /Applications/VPN Switch.app
#     (writable by the admin group on this machine; no sudo needed)
#   - bin/vpn-ctl.sh                              -> "$HOME/Library/Application Support/vpn-switch/bin/vpn-ctl.sh"
#   - lib/*.sh                                    -> "$HOME/Library/Application Support/vpn-switch/lib/*.sh"
#     (vpn-ctl.sh resolves its libs as "<its own dir>/../lib/*.sh" -- the
#     case-guard repo-root pattern -- so bin/ and lib/ are installed as
#     siblings under .../vpn-switch/, matching that layout exactly.)
#
# INSTALL_PREFIX=/usr/local is an OPT-IN alternative install location for the
# scripts (NOT the app, which always goes to /Applications). It requires
# sudo. This script NEVER runs sudo itself -- when INSTALL_PREFIX=/usr/local
# is set, it prints the exact commands for a human to run, does not touch
# /usr/local, and then continues with the normal user-level install so the
# machine is usable either way.
#
# This script never touches the IKEv2 profile, NordVPN credentials, or any
# *.mobileconfig / *.env file.
#
# Idempotent: safe to re-run. Re-running updates the app and scripts in
# place and does not duplicate the login item (the login item is registered
# separately, from the app's own "Launch at login" menu toggle -- this
# script does not register it).
#
# Repo conventions: set -u, no set -e, case-guard BASH_SOURCE resolution,
# bash 3.2 compatible (no 'declare -A', no '${var,,}'). No sudo. No dig.

set -u

case "${BASH_SOURCE[0]}" in
    */*) SCRIPT_PARENT="${BASH_SOURCE[0]%/*}" ;;
    *)   SCRIPT_PARENT="." ;;
esac
if ! REPO_ROOT="$(cd "${SCRIPT_PARENT}/.." 2>/dev/null && pwd)"; then
    echo "install-vpn-switch: could not resolve repo root" >&2
    exit 1
fi

APP_BUILD_SCRIPT="${REPO_ROOT}/app/build.sh"
APP_BUILD_OUTPUT="${REPO_ROOT}/app/build/VPNSwitch.app"
APP_DEST="/Applications/VPN Switch.app"

INSTALL_PREFIX="${INSTALL_PREFIX:-}"

DEFAULT_INSTALL_ROOT="${HOME}/Library/Application Support/vpn-switch"
DEFAULT_BIN_DIR="${DEFAULT_INSTALL_ROOT}/bin"
DEFAULT_LIB_DIR="${DEFAULT_INSTALL_ROOT}/lib"

echo "=== VPN Switch install ==="
echo

# --- step 1: build the app -------------------------------------------------

echo "==> [1/4] Building app via ${APP_BUILD_SCRIPT}"
if [ ! -x "${APP_BUILD_SCRIPT}" ]; then
    echo "install-vpn-switch: missing or non-executable ${APP_BUILD_SCRIPT}" >&2
    exit 1
fi
if ! "${APP_BUILD_SCRIPT}"; then
    echo "install-vpn-switch: app/build.sh failed" >&2
    exit 1
fi
if [ ! -d "${APP_BUILD_OUTPUT}" ]; then
    echo "install-vpn-switch: expected build output not found at ${APP_BUILD_OUTPUT}" >&2
    exit 1
fi
echo

# --- step 2: install bin/vpn-ctl.sh + lib/*.sh -----------------------------

echo "==> [2/4] Installing control scripts"

install_scripts_to() {
    _bin_dir="$1"
    _lib_dir="$2"

    echo "    bin: ${_bin_dir}"
    echo "    lib: ${_lib_dir}"

    if ! mkdir -p "${_bin_dir}"; then
        echo "install-vpn-switch: could not create ${_bin_dir}" >&2
        return 1
    fi
    if ! mkdir -p "${_lib_dir}"; then
        echo "install-vpn-switch: could not create ${_lib_dir}" >&2
        return 1
    fi

    if ! cp "${REPO_ROOT}/bin/vpn-ctl.sh" "${_bin_dir}/vpn-ctl.sh"; then
        echo "install-vpn-switch: failed to copy vpn-ctl.sh" >&2
        return 1
    fi
    chmod +x "${_bin_dir}/vpn-ctl.sh"

    _lib_ok=1
    for _lib_file in "${REPO_ROOT}"/lib/*.sh; do
        [ -e "${_lib_file}" ] || continue
        _lib_base="${_lib_file##*/}"
        if ! cp "${_lib_file}" "${_lib_dir}/${_lib_base}"; then
            echo "install-vpn-switch: failed to copy ${_lib_base}" >&2
            _lib_ok=0
            continue
        fi
        chmod +x "${_lib_dir}/${_lib_base}"
        echo "    installed ${_lib_base}"
    done
    [ "${_lib_ok}" = "1" ] || return 1
    return 0
}

if [ -n "${INSTALL_PREFIX}" ]; then
    # Opt-in system-wide install: never run sudo, only print the commands.
    echo "    INSTALL_PREFIX=${INSTALL_PREFIX} set -- opt-in system-wide install requested."
    echo "    This script does NOT run sudo. Run these commands yourself:"
    echo
    echo "        sudo mkdir -p '${INSTALL_PREFIX}/bin' '${INSTALL_PREFIX}/lib'"
    echo "        sudo cp '${REPO_ROOT}/bin/vpn-ctl.sh' '${INSTALL_PREFIX}/bin/vpn-ctl.sh'"
    for _lib_file in "${REPO_ROOT}"/lib/*.sh; do
        [ -e "${_lib_file}" ] || continue
        _lib_base="${_lib_file##*/}"
        echo "        sudo cp '${_lib_file}' '${INSTALL_PREFIX}/lib/${_lib_base}'"
    done
    echo "        sudo chmod +x '${INSTALL_PREFIX}/bin/vpn-ctl.sh' '${INSTALL_PREFIX}/lib/'*.sh"
    echo
    echo "    NOTE: vpn-ctl.sh resolves its libs as '<its own dir>/../lib/*.sh',"
    echo "    so under INSTALL_PREFIX the layout must be '\${INSTALL_PREFIX}/bin/vpn-ctl.sh'"
    echo "    and '\${INSTALL_PREFIX}/lib/*.sh' as siblings of 'bin/' -- adjust the"
    echo "    mkdir path above if your INSTALL_PREFIX layout differs."
    echo
    echo "    This script is still installing the no-sudo default location below"
    echo "    so the app has something to run against right away."
    echo
fi

if ! install_scripts_to "${DEFAULT_BIN_DIR}" "${DEFAULT_LIB_DIR}"; then
    echo "install-vpn-switch: failed to install control scripts" >&2
    exit 1
fi
echo

# --- step 3: install the app to /Applications ------------------------------

echo "==> [3/4] Installing app to ${APP_DEST}"
if [ -d "${APP_DEST}" ]; then
    echo "    removing existing ${APP_DEST}"
    if ! rm -rf "${APP_DEST}"; then
        echo "install-vpn-switch: failed to remove existing ${APP_DEST}" >&2
        exit 1
    fi
fi
# Copy into a temp name in the destination directory, then rename -- more
# atomic than a direct multi-file cp into the final name (a reader between
# the rm -rf above and completion of a direct cp would see a missing or
# partial bundle either way, but renaming after a complete copy narrows that
# window to a single fast filesystem op).
APP_DEST_TMP="${APP_DEST}.installing-$$"
if ! cp -R "${APP_BUILD_OUTPUT}" "${APP_DEST_TMP}"; then
    echo "install-vpn-switch: failed to copy app bundle" >&2
    rm -rf "${APP_DEST_TMP}"
    exit 1
fi
if ! mv "${APP_DEST_TMP}" "${APP_DEST}"; then
    echo "install-vpn-switch: failed to move app bundle into place" >&2
    rm -rf "${APP_DEST_TMP}"
    exit 1
fi
echo "    installed ${APP_DEST}"

echo "==> verifying code signature"
if codesign -v "${APP_DEST}" 2>&1; then
    echo "    codesign -v: OK"
else
    echo "install-vpn-switch: codesign -v failed for ${APP_DEST}" >&2
    exit 1
fi
echo

# --- step 4: summary ---------------------------------------------------------

echo "==> [4/4] Done"
echo
echo "Installed:"
echo "  App:          ${APP_DEST}"
echo "  vpn-ctl.sh:   ${DEFAULT_BIN_DIR}/vpn-ctl.sh"
echo "  libs:         ${DEFAULT_LIB_DIR}/"
echo
echo "Not touched: the IKEv2 profile (*.mobileconfig), NordVPN credentials, Shortcuts.app."
echo
echo "Launch: open '${APP_DEST}'"
echo
echo "To enable Launch at login: open the app, click the menu bar icon, toggle 'Launch at login'."

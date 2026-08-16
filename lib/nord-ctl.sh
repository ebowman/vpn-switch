#!/bin/bash
# nord-ctl.sh — sourceable functions to control and query NordVPN's native
# IKEv2 profile ("NordVPN IKEv2"), via the Shortcuts CLI.
#
# Usage:
#   source lib/nord-ctl.sh
#   nord_state                 # print current mode: up|down|app|app+ikev2|unknown
#   nord_connect                # invoke the "NordVPN On" shortcut, verify by reality
#   nord_disconnect              # invoke the "NordVPN Off" shortcut, verify by reality
#   nord_wait_for up 30         # poll nord_state until it matches or 30s elapse
#
# This file has NO side effects when sourced: it only defines functions and
# a couple of read-only constants. It performs no mutation and issues no
# external calls at source time (matches lib/tailscale-ctl.sh's contract).
# 'set -u', no 'set -e'. Bash 3.2 compatible: no 'declare -A', no
# '${var,,}'.
#
# CONTROL HANDLE (see dns-config-qsk.10's control-handle investigation for
# the full dead-end list): scutil --nc CANNOT address the profile-installed
# IKEv2 VPN at all (it lives in NetworkExtension's store, not classic
# SystemConfiguration). 'profiles install' is removed on this macOS. UI
# scripting of System Settings > VPN sees an empty accessibility tree. The
# only viable handle is a pair of human-created Shortcuts using the built-in
# "Set VPN" action (Connect / Disconnect modes) named exactly "NordVPN On"
# and "NordVPN Off" (override via NORD_SHORTCUT_ON / NORD_SHORTCUT_OFF), run
# via 'shortcuts run <name>'. See docs/switcher/nord-ikev2-setup.md for the
# human setup steps.
#
# CRITICAL QUIRK, measured: 'shortcuts run <name>' on a MISSING shortcut
# still exits 0 and only prints "Couldn't find shortcut ..." on stderr — the
# CLI's own exit code is UNTRUSTWORTHY for both "shortcut exists" and
# "shortcut succeeded". This library never trusts it:
#   (a) before invoking, nord_connect/nord_disconnect check 'shortcuts list'
#       for the exact shortcut name FIRST, and fail fast (exit 3) with a
#       fixed message if it is absent — without invoking anything, so no
#       state can change.
#   (b) after invoking, they VERIFY REALITY via nord_wait_for, which in turn
#       delegates to nord_state (itself derived from lib/nord-detect.sh's
#       nord_mode: ipsec0 inet address and/or the 103.86.x resolvers) —
#       never from any Shortcuts/scutil status API.
#
# nord_state mode mapping (nord_mode -> nord_state):
#   nord_mode may print a bare mode or mode(iface), e.g. "ikev2(ipsec0)".
#   ikev2*      -> up            (the IKEv2 profile: the one this lib drives)
#   absent      -> down
#   app*        -> app           (NordVPN app tunnel only — unsupported combo)
#   app+ikev2   -> app+ikev2     (both — unsupported combo, still surfaced)
#   anything else (nord_mode unavailable/unparsable) -> unknown
#
# Testing hooks: this library performs NO detection of its own — nord_state
# is a thin wrapper around lib/nord-detect.sh's nord_mode, so the standard
# NORD_DETECT_IFCONFIG_OVERRIDE / NORD_DETECT_SCUTIL_DNS_OVERRIDE env vars
# (see lib/nord-detect.sh) fully control nord_state's answer for unit
# testing nord_wait_for without touching real network state or requiring
# the shortcuts to exist. NORD_CTL_SHORTCUTS_LIST_OVERRIDE, if set (even to
# an empty string), is used in place of real 'shortcuts list' output by the
# missing-shortcut check, for testing that path without depending on what
# shortcuts actually exist on the machine running the tests.

set -u

# Shortcut names. Overridable so a differently-named pair can be used
# without editing this file.
NORD_SHORTCUT_ON="${NORD_SHORTCUT_ON:-NordVPN On}"
NORD_SHORTCUT_OFF="${NORD_SHORTCUT_OFF:-NordVPN Off}"

# Default per-call timeout (seconds) for 'shortcuts run' and 'shortcuts
# list'. 'shortcuts run' itself does not prove anything (see the quirk
# above) so this only bounds how long a hung Shortcuts process can block
# the caller before nord_wait_for's own verification loop takes over.
NORD_CTL_CALL_TIMEOUT="${NORD_CTL_CALL_TIMEOUT:-15}"

# Default bounded wait (seconds) used by nord_connect/nord_disconnect after
# invoking a shortcut, before verifying reality via nord_wait_for. Kept
# modest: tailscale-ctl.sh's equivalent transitions settled in ~1s in
# measured testing; IKEv2 connect/disconnect has not yet been measured on
# this machine (the shortcuts do not exist yet), so this errs generous
# without being unbounded.
NORD_CTL_VERIFY_TIMEOUT="${NORD_CTL_VERIFY_TIMEOUT:-30}"

# Resolve the directory this file lives in, so nord-detect.sh can be
# sourced relative to it regardless of the caller's cwd. Bash 3.2 safe.
case "${BASH_SOURCE[0]}" in
    */*) _NORD_CTL_SELF_DIR="${BASH_SOURCE[0]%/*}" ;;
    *)   _NORD_CTL_SELF_DIR="." ;;
esac

# Pull in nord_mode. Do not abort the sourcing caller if it is missing —
# nord_state degrades to "unknown" instead (matches the no-side-effects,
# no-exit contract of the other libs; a lib must never take down a caller
# just because a sibling file moved).
if [ -f "${_NORD_CTL_SELF_DIR}/nord-detect.sh" ]; then
    # shellcheck source=lib/nord-detect.sh
    . "${_NORD_CTL_SELF_DIR}/nord-detect.sh"
    _NORD_CTL_DETECT_AVAILABLE=1
else
    _NORD_CTL_DETECT_AVAILABLE=0
fi

# Resolve a usable 'timeout' command, same convention as tailscale-ctl.sh.
_nord_ctl_timeout_cmd() {
    if command -v timeout >/dev/null 2>&1; then
        echo "timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
        echo "gtimeout"
    else
        echo ""
    fi
}

# Run "$@" bounded by NORD_CTL_CALL_TIMEOUT seconds if a timeout command is
# available; otherwise run it unbounded. Returns the wrapped command's exit
# status (or 124 on timeout, matching GNU timeout's convention).
_nord_ctl_run_bounded() {
    local tcmd
    tcmd="$(_nord_ctl_timeout_cmd)"
    if [ -n "${tcmd}" ]; then
        "${tcmd}" "${NORD_CTL_CALL_TIMEOUT}" "$@"
        return $?
    fi
    "$@"
    return $?
}

# True (0) if $1 is present as an exact line in 'shortcuts list' output.
# Reads NORD_CTL_SHORTCUTS_LIST_OVERRIDE instead of invoking the real
# command when that var is set (even to empty), for testing.
_nord_ctl_shortcut_exists() {
    local name="$1" listing
    if [ -n "${NORD_CTL_SHORTCUTS_LIST_OVERRIDE+x}" ]; then
        listing="${NORD_CTL_SHORTCUTS_LIST_OVERRIDE}"
    else
        listing="$(_nord_ctl_run_bounded shortcuts list 2>/dev/null)"
    fi
    printf '%s\n' "${listing}" | grep -Fxq -- "${name}"
}

# nord_state — print the current NordVPN mode as one of: up | down | app |
# app+ikev2 | unknown. Delegates entirely to lib/nord-detect.sh's nord_mode
# (reality-derived: ipsec0 inet address and/or the 103.86.x/100.64.0.2
# resolvers — never a status API). Never aborts the caller; always prints
# exactly one line and returns 0.
#
# Mapping: nord_mode's "ikev2" / "ikev2(iface)" -> "up" (this library only
# drives the IKEv2 profile, so "up" unambiguously means IKEv2 is up).
# "absent" -> "down". "app" / "app(iface)" -> "app". "app+ikev2" is passed
# through unchanged (both tunnels present -- an unsupported combination that
# callers must still be able to see, per dns-config-qsk.10's findings).
nord_state() {
    if [ "${_NORD_CTL_DETECT_AVAILABLE}" -ne 1 ]; then
        echo "unknown"
        return 0
    fi

    local mode
    mode="$(nord_mode)"
    case "${mode}" in
        ikev2|ikev2\(*) echo "up" ;;
        absent)         echo "down" ;;
        app+ikev2)      echo "app+ikev2" ;;
        app|app\(*)     echo "app" ;;
        *)              echo "unknown" ;;
    esac
    return 0
}

# nord_wait_for <up|down|app|app+ikev2|unknown> <timeout_seconds> — poll
# nord_state every 0.5s until it equals $1 or $2 seconds have elapsed.
#
# Returns: 0 as soon as nord_state == $1. Returns 1 if timeout_seconds
# elapses without a match (a final check is made right at the deadline
# before giving up, matching ts_wait_for's convention). Returns 2 (usage
# error) without polling if either argument is missing or timeout_seconds
# is not a non-negative integer.
nord_wait_for() {
    local want="${1:-}" timeout_s="${2:-}"
    if [ -z "${want}" ] || [ -z "${timeout_s}" ]; then
        return 2
    fi
    case "${timeout_s}" in
        ''|*[!0-9]*) return 2 ;;
    esac

    local elapsed_x10=0 timeout_x10=$((timeout_s * 10))
    while [ "${elapsed_x10}" -le "${timeout_x10}" ]; do
        if [ "$(nord_state)" = "${want}" ]; then
            return 0
        fi
        sleep 0.5
        elapsed_x10=$((elapsed_x10 + 5))
    done

    [ "$(nord_state)" = "${want}" ] && return 0
    return 1
}

# nord_connect — bring the "NordVPN IKEv2" profile up via the "NordVPN On"
# shortcut (name overridable: NORD_SHORTCUT_ON), then verify by reality.
#
# Sequence:
#   1. Check 'shortcuts list' for the exact shortcut name. If absent,
#      return 3 immediately (message on stderr) WITHOUT invoking anything —
#      no state can change on this path.
#   2. Invoke 'shortcuts run "<name>"', bounded by NORD_CTL_CALL_TIMEOUT.
#      Its exit code is NOT trusted (measured: rc 0 even when the shortcut
#      does not exist -- and by extension, no stronger guarantee is assumed
#      for other failure modes either).
#   3. Wait up to NORD_CTL_VERIFY_TIMEOUT seconds (override via $1) for
#      nord_state to become "up" via nord_wait_for.
#
# Returns:
#   0  nord_state verified "up" within the timeout
#   1  timeout: nord_state never reached "up"
#   3  shortcut "<NORD_SHORTCUT_ON>" not found in 'shortcuts list'
#
# Arguments:
#   $1  optional override for the verify timeout (seconds); defaults to
#       NORD_CTL_VERIFY_TIMEOUT.
nord_connect() {
    local verify_timeout="${1:-${NORD_CTL_VERIFY_TIMEOUT}}"

    if ! _nord_ctl_shortcut_exists "${NORD_SHORTCUT_ON}"; then
        echo "shortcut '${NORD_SHORTCUT_ON}' not found — create it in Shortcuts.app: Set VPN → NordVPN IKEv2 → Connect (see docs/switcher/nord-ikev2-setup.md)" >&2
        return 3
    fi

    _nord_ctl_run_bounded shortcuts run "${NORD_SHORTCUT_ON}" >/dev/null 2>&1

    if nord_wait_for up "${verify_timeout}"; then
        return 0
    fi
    return 1
}

# nord_disconnect — bring the "NordVPN IKEv2" profile down via the
# "NordVPN Off" shortcut (name overridable: NORD_SHORTCUT_OFF), then verify
# by reality. Same sequence, quirks, and trust model as nord_connect.
#
# Returns:
#   0  nord_state verified "down" within the timeout
#   1  timeout: nord_state never reached "down"
#   3  shortcut "<NORD_SHORTCUT_OFF>" not found in 'shortcuts list'
#
# Arguments:
#   $1  optional override for the verify timeout (seconds); defaults to
#       NORD_CTL_VERIFY_TIMEOUT.
nord_disconnect() {
    local verify_timeout="${1:-${NORD_CTL_VERIFY_TIMEOUT}}"

    if ! _nord_ctl_shortcut_exists "${NORD_SHORTCUT_OFF}"; then
        echo "shortcut '${NORD_SHORTCUT_OFF}' not found — create it in Shortcuts.app: Set VPN → NordVPN IKEv2 → Disconnect (see docs/switcher/nord-ikev2-setup.md)" >&2
        return 3
    fi

    _nord_ctl_run_bounded shortcuts run "${NORD_SHORTCUT_OFF}" >/dev/null 2>&1

    if nord_wait_for down "${verify_timeout}"; then
        return 0
    fi
    return 1
}

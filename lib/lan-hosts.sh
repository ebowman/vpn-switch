#!/bin/bash
# lan-hosts.sh -- sourceable helpers for reading lan-hosts.conf, the single
# source of truth for LAN host addresses (ADR-003, dns-config-j9y.3).
#
# Usage:
#   source lib/lan-hosts.sh
#   lan_hosts_lan_ip streamy       # prints "192.0.2.4", or nothing if unknown
#   lan_hosts_tailnet_ip streamy   # prints "100.64.10.4", or nothing if unknown
#   lan_hosts_ip streamy           # ALIAS of lan_hosts_lan_ip (back-compat)
#   lan_hosts_names                # prints one host name per line
#
# This file has NO side effects when sourced: it only defines functions and
# resolves LAN_HOSTS_CONF (see below). It performs no mutation and issues no
# external calls at source time.
#
# Path resolution (dns-config-c4r): LAN_HOSTS_CONF is resolved, in order:
#   1. The LAN_HOSTS_CONF environment variable, if already set -- takes
#      precedence over everything below, so callers wanting a specific conf
#      file (e.g. a copy already generated elsewhere) can set it before
#      sourcing this file, or at call time.
#   2. "<repo root>/config/lan-hosts.conf" (repo root resolved relative to
#      this file's own location, the case-guard repo-root pattern also used
#      by lib/tailscale-ctl.sh and friends) -- used IF that file is readable.
#      This is the REAL, user-owned hosts file for a repo checkout; it is
#      gitignored and never shipped (see config/lan-hosts.conf.example).
#   3. "$HOME/Library/Application Support/vpn-switch/config/lan-hosts.conf"
#      -- used IF that file is readable and (2) was not. This is where
#      bin/install-vpn-switch.sh and ScriptBundle.swift create/maintain the
#      real, user-owned hosts file for an installed (non-checkout) copy of
#      this script.
#   If neither (2) nor (3) is readable, LAN_HOSTS_CONF is left pointing at
#   candidate (2) so callers' "unreadable"/missing-file error messages stay
#   meaningful (they name a real, expected path rather than an empty string).
#
# File format (lan-hosts.conf): hosts-style, "<name> <lan-ip> <tailnet-ip>"
# per line. '#' starts a comment (whole-line or trailing); blank lines are
# ignored. The third column (tailnet IP) is a fallback value only -- callers
# wanting the LIVE tailnet address should prefer 'tailscale status --json'
# (see lib/lan-dns.sh's lan_dns_render) and fall back to this column only
# when no live peer entry is found.
#
# Repo conventions: set -u, no set -e (probe functions return empty/nonzero
# on missing data rather than aborting a sourcing caller). Bash 3.2
# compatible: no 'declare -A', no '${var,,}'.

set -u

if [ -z "${LAN_HOSTS_CONF:-}" ]; then
    _LAN_HOSTS_SH_SOURCE="${BASH_SOURCE[0]}"
    case "${_LAN_HOSTS_SH_SOURCE}" in
        */*) _LAN_HOSTS_SH_PARENT="${_LAN_HOSTS_SH_SOURCE%/*}" ;;
        *)   _LAN_HOSTS_SH_PARENT="." ;;
    esac
    if _LAN_HOSTS_SH_DIR="$(cd "${_LAN_HOSTS_SH_PARENT}" 2>/dev/null && pwd)"; then
        _LAN_HOSTS_SH_REPO_CANDIDATE="${_LAN_HOSTS_SH_DIR}/../config/lan-hosts.conf"
    else
        _LAN_HOSTS_SH_REPO_CANDIDATE="./config/lan-hosts.conf"
    fi
    _LAN_HOSTS_SH_SUPPORT_CANDIDATE="${HOME}/Library/Application Support/vpn-switch/config/lan-hosts.conf"

    if [ -r "${_LAN_HOSTS_SH_REPO_CANDIDATE}" ]; then
        LAN_HOSTS_CONF="${_LAN_HOSTS_SH_REPO_CANDIDATE}"
    elif [ -r "${_LAN_HOSTS_SH_SUPPORT_CANDIDATE}" ]; then
        LAN_HOSTS_CONF="${_LAN_HOSTS_SH_SUPPORT_CANDIDATE}"
    else
        LAN_HOSTS_CONF="${_LAN_HOSTS_SH_REPO_CANDIDATE}"
    fi

    unset _LAN_HOSTS_SH_SOURCE _LAN_HOSTS_SH_PARENT _LAN_HOSTS_SH_DIR
    unset _LAN_HOSTS_SH_REPO_CANDIDATE _LAN_HOSTS_SH_SUPPORT_CANDIDATE
fi

# lan_hosts_lan_ip <name> -- print the LAN IP (column 2) for <name> from
# LAN_HOSTS_CONF, or nothing (empty stdout, exit 1) if the name is not found
# or the conf file is missing/unreadable. Never aborts the caller.
lan_hosts_lan_ip() {
    local name="${1:-}"
    [ -n "${name}" ] || return 1
    [ -r "${LAN_HOSTS_CONF}" ] || return 1
    /usr/bin/awk -v want="${name}" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            sub(/#.*/, "");
            if ($1 == want && $2 != "") { print $2; found=1; exit }
        }
        END { if (!found) exit 1 }
    ' "${LAN_HOSTS_CONF}"
}

# lan_hosts_ip <name> -- ALIAS of lan_hosts_lan_ip, kept for backward
# compatibility with existing callers.
lan_hosts_ip() {
    lan_hosts_lan_ip "$@"
}

# lan_hosts_tailnet_ip <name> -- print the fallback tailnet IP (column 3) for
# <name> from LAN_HOSTS_CONF, or nothing (empty stdout, exit 1) if the name
# is not found, the column is absent, or the conf file is missing/unreadable.
# Never aborts the caller. This is a FALLBACK value only -- prefer a live
# 'tailscale status --json' lookup when one is available (see
# lib/lan-dns.sh).
lan_hosts_tailnet_ip() {
    local name="${1:-}"
    [ -n "${name}" ] || return 1
    [ -r "${LAN_HOSTS_CONF}" ] || return 1
    /usr/bin/awk -v want="${name}" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            sub(/#.*/, "");
            if ($1 == want && $3 != "") { print $3; found=1; exit }
        }
        END { if (!found) exit 1 }
    ' "${LAN_HOSTS_CONF}"
}

# lan_hosts_names -- print each configured host name, one per line, in the
# order they appear in LAN_HOSTS_CONF. Prints nothing if the conf file is
# missing/unreadable.
lan_hosts_names() {
    [ -r "${LAN_HOSTS_CONF}" ] || return 1
    /usr/bin/awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            sub(/#.*/, "");
            if ($1 != "" && $2 != "") { print $1 }
        }
    ' "${LAN_HOSTS_CONF}"
}

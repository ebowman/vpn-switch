#!/bin/bash
# lan-hosts.sh -- sourceable helpers for reading config/lan-hosts.conf, the
# single source of truth for LAN host addresses (ADR-003, dns-config-j9y.3).
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
# Path resolution (case-guard repo-root pattern, matching lib/tailscale-ctl.sh
# and friends): LAN_HOSTS_CONF defaults to "<repo root>/config/lan-hosts.conf"
# where "repo root" is resolved relative to this file's own location. This is
# OVERRIDABLE via the LAN_HOSTS_CONF environment variable, which
# bin/lan-dns-install.sh's installed copy under
# "$HOME/Library/Application Support/vpn-switch/lib/lan-hosts.sh" is expected
# to rely on if it is ever installed standalone away from the repo checkout
# -- callers that want a specific conf file (e.g. a copy already generated
# elsewhere) can set LAN_HOSTS_CONF before sourcing this file, or at call
# time, and it takes precedence over the repo-relative default.
#
# File format (config/lan-hosts.conf): hosts-style,
# "<name> <lan-ip> <tailnet-ip>" per line. '#' starts a comment (whole-line
# or trailing); blank lines are ignored. The third column (tailnet IP) is a
# fallback value only -- callers wanting the LIVE tailnet address should
# prefer 'tailscale status --json' (see lib/lan-dns.sh's lan_dns_render) and
# fall back to this column only when no live peer entry is found.
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
        LAN_HOSTS_CONF="${_LAN_HOSTS_SH_DIR}/../config/lan-hosts.conf"
    else
        LAN_HOSTS_CONF="./config/lan-hosts.conf"
    fi
    unset _LAN_HOSTS_SH_SOURCE _LAN_HOSTS_SH_PARENT _LAN_HOSTS_SH_DIR
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

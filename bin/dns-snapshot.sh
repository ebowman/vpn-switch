#!/bin/bash
# dns-snapshot.sh — capture a read-only snapshot of DNS/network state.
#
# Usage: dns-snapshot.sh [label]
#   label   optional snapshot label (default: "snapshot")
#
# Writes snapshots/<label>.txt and echoes the same report to stdout.
# snapshots/ is gitignored; its contents are local-only and never committed.
# Read-only: no sudo, no network/config mutation. Intentionally does NOT
# use 'set -e' since probe commands are expected to fail without aborting
# the run.
set -u

LABEL="${1:-snapshot}"
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
case "${SCRIPT_SOURCE}" in
    */*) SCRIPT_PARENT="${SCRIPT_SOURCE%/*}" ;;
    *)   SCRIPT_PARENT="." ;;
esac
if ! SCRIPT_DIR="$(cd "${SCRIPT_PARENT}" && pwd)"; then
    echo "Error: could not resolve script directory from '${SCRIPT_PARENT}'" >&2
    exit 1
fi
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load the shared NordVPN mode detector (ikev2 vs app vs app+ikev2 vs
# absent). Degrade to "unknown" rather than aborting if it is missing.
NORD_DETECT_LIB="${REPO_ROOT}/lib/nord-detect.sh"
if [ -f "${NORD_DETECT_LIB}" ]; then
    # shellcheck source=lib/nord-detect.sh
    . "${NORD_DETECT_LIB}"
    NORD_DETECT_AVAILABLE=1
else
    NORD_DETECT_AVAILABLE=0
fi

# Load lib/lan-hosts.sh so the probed host names/addresses below are derived
# from the configured lan-hosts.conf rather than hardcoded (dns-config-c4r).
# Degrade to an empty host list if unavailable/unreadable -- the resolution
# and reachability sections below just print nothing for those probes.
LAN_HOSTS_LIB="${REPO_ROOT}/lib/lan-hosts.sh"
if [ -f "${LAN_HOSTS_LIB}" ]; then
    # shellcheck source=lib/lan-hosts.sh
    . "${LAN_HOSTS_LIB}"
    LAN_HOSTS_AVAILABLE=1
else
    LAN_HOSTS_AVAILABLE=0
fi

# The tailnet's MagicDNS suffix (e.g. "tailXXXX.ts.net"), derived from a live
# 'tailscale status --json' rather than hardcoded. Empty if unavailable --
# callers must SKIP any FQDN-suffixed probe rather than guessing.
TAILNET_SUFFIX=""
detect_tailnet_suffix() {
    # Deliberately absolute, no PATH fallback (matches lib/tailscale-ctl.sh's
    # TS_CTL_BIN convention).
    local ts_bin="/usr/local/bin/tailscale"
    [ -x "${ts_bin}" ] || return 1
    local json
    json="$("${ts_bin}" status --json 2>/dev/null)" || return 1
    [ -n "${json}" ] || return 1
    if command -v /usr/bin/python3 >/dev/null 2>&1; then
        TAILNET_SUFFIX="$(printf '%s' "${json}" | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("MagicDNSSuffix", "") or "")
except Exception:
    pass
' 2>/dev/null)"
    fi
    [ -n "${TAILNET_SUFFIX}" ]
}
detect_tailnet_suffix || TAILNET_SUFFIX=""

SNAPSHOT_DIR="${REPO_ROOT}/snapshots"
OUTFILE="${SNAPSHOT_DIR}/${LABEL}.txt"
SNAPSHOT_WRITE_OK=1

if ! mkdir -p "${SNAPSHOT_DIR}" 2>/dev/null; then
    echo "Warning: could not create ${SNAPSHOT_DIR}; report will be printed to stdout only" >&2
    SNAPSHOT_DIR=""
    SNAPSHOT_WRITE_OK=0
fi

# Run a command, printing its output, or a failure marker if it errors
# or is unavailable. Never lets the caller's failure abort the script.
run_or_fail() {
    local output
    if output="$("$@" 2>&1)"; then
        printf '%s\n' "${output}"
    else
        printf '(command failed/unavailable)\n'
    fi
}

resolve_host() {
    local host="$1"
    local output
    echo "${host}:"
    if output="$(dscacheutil -q host -a name "${host}" 2>/dev/null)"; then
        local ips
        ips="$(printf '%s\n' "${output}" | grep '^ip_address:')"
        if [ -n "${ips}" ]; then
            printf '%s\n' "${ips}"
        else
            echo "(no answer)"
        fi
    else
        echo "(no answer)"
    fi
}

check_reachability() {
    local addr="$1"
    if ping -c1 -W1000 "${addr}" >/dev/null 2>&1; then
        echo "${addr}: ok"
    else
        echo "${addr}: fail"
    fi
}

tailscale_status() {
    local ts_bin="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    if [ -x "${ts_bin}" ]; then
        run_or_fail "${ts_bin}" status
    elif command -v tailscale >/dev/null 2>&1; then
        run_or_fail tailscale status
    else
        echo "tailscale CLI not found"
    fi
}

build_report() {
    echo "=== date ==="
    local now
    if now="$(date 2>/dev/null)"; then
        echo "${now} (label: ${LABEL})"
    else
        echo "(command failed/unavailable) (label: ${LABEL})"
    fi
    echo

    echo "=== routes ==="
    run_or_fail bash -c "netstat -rn -f inet | head -20"
    echo

    echo "=== en0 ==="
    run_or_fail bash -c "ifconfig en0 | grep 'inet '"
    echo

    echo "=== tunnels ==="
    # Prefix each matching 'inet' line with its owning interface name, so
    # both Tailscale/NordVPN-app utuns (10.x/100.x) and the NordVPN IKEv2
    # profile's ipsec0 (10.6.x here) are attributable. A plain '-B1' grep
    # is not reliable for ipsec0: on this interface an 'options=...' line
    # sits between the header and 'inet', so the preceding line is not the
    # interface name. awk tracks the current interface across lines instead.
    run_or_fail bash -c "ifconfig | awk '/^[a-zA-Z0-9]+:/{iface=\$1} /inet 10\.|inet 100\./{print iface, \$0}'"
    echo

    echo "=== nord-mode ==="
    if [ "${NORD_DETECT_AVAILABLE}" -eq 1 ]; then
        nord_mode
    else
        echo "unknown (lib/nord-detect.sh not found)"
    fi
    echo

    echo "=== scutil ==="
    run_or_fail scutil --dns
    echo

    echo "=== tailscale ==="
    tailscale_status
    echo

    echo "=== resolution ==="
    if [ "${LAN_HOSTS_AVAILABLE}" -eq 1 ]; then
        local _host
        while IFS= read -r _host; do
            [ -n "${_host}" ] || continue
            resolve_host "${_host}"
            resolve_host "${_host}.local"
            if [ -n "${TAILNET_SUFFIX}" ]; then
                resolve_host "${_host}.${TAILNET_SUFFIX}"
            else
                echo "${_host}.<tailnet-suffix>:"
                echo "(SKIP: tailnet MagicDNS suffix unavailable -- 'tailscale status --json' unreachable/not found)"
            fi
        done < <(lan_hosts_names | head -2)
    else
        echo "(SKIP: lib/lan-hosts.sh unavailable -- cannot derive configured host names)"
    fi
    echo

    echo "=== reachability ==="
    if [ "${LAN_HOSTS_AVAILABLE}" -eq 1 ]; then
        local _host
        while IFS= read -r _host; do
            [ -n "${_host}" ] || continue
            local _tnip _lanip
            _tnip="$(lan_hosts_tailnet_ip "${_host}")"
            _lanip="$(lan_hosts_lan_ip "${_host}")"
            [ -n "${_tnip}" ] && check_reachability "${_tnip}"
            [ -n "${_lanip}" ] && check_reachability "${_lanip}"
        done < <(lan_hosts_names | head -2)
    else
        echo "(SKIP: lib/lan-hosts.sh unavailable -- cannot derive configured host addresses)"
    fi
}

REPORT="$(build_report)"

if [ -n "${SNAPSHOT_DIR}" ] && command -v tee >/dev/null 2>&1; then
    if ! printf '%s\n' "${REPORT}" | tee "${OUTFILE}"; then
        SNAPSHOT_WRITE_OK=0
    fi
else
    printf '%s\n' "${REPORT}"
    SNAPSHOT_WRITE_OK=0
fi

if [ "${SNAPSHOT_WRITE_OK}" -eq 0 ]; then
    echo "Error: snapshot report could not be written to ${OUTFILE}" >&2
    exit 1
fi

exit 0

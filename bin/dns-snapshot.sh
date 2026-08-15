#!/bin/bash
# dns-snapshot.sh — capture a read-only snapshot of DNS/network state.
#
# Usage: dns-snapshot.sh [label]
#   label   optional snapshot label (default: "snapshot")
#
# Writes snapshots/<label>.txt and echoes the same report to stdout.
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
    run_or_fail bash -c "ifconfig | grep -B1 'inet 10\.\|inet 100\.'"
    echo

    echo "=== scutil ==="
    run_or_fail scutil --dns
    echo

    echo "=== tailscale ==="
    tailscale_status
    echo

    echo "=== resolution ==="
    resolve_host "streamy"
    resolve_host "streamy.local"
    resolve_host "streamy.tailXXXX.ts.net"
    resolve_host "mac-mini"
    resolve_host "mac-mini.local"
    resolve_host "mac-mini.tailXXXX.ts.net"
    echo

    echo "=== reachability ==="
    check_reachability "100.64.10.4"
    check_reachability "100.64.10.65"
    check_reachability "192.0.2.4"
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

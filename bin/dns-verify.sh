#!/bin/bash
# dns-verify.sh — verify that the bare hostnames and services this repo cares
# about resolve and are reachable in the CURRENT network state.
#
# Usage: dns-verify.sh
#
# Prints a PASS/FAIL/SKIP table (one line per check) plus a leading network
# state summary, and exits non-zero if any check FAILs. SKIPs do not affect
# the exit code. Read-only: no sudo, no config mutation.
#
# Intentionally does NOT use 'set -e' since probe commands are expected to
# fail without aborting the run — failures are data, not script errors.
#
# Testing hook: DNS_VERIFY_EXPECT_<HOST>_OVERRIDE (host name upper-cased,
# '-' -> '_') lets the staleness check be forced to compare against an
# arbitrary IP instead of the live Tailscale address, so the FAIL path can
# be exercised without mutating /etc/hosts. Not used in normal operation.

set -u

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
export REPO_ROOT

HOSTS=(streamy mac-mini)

# Portable "map keyed by host name" helpers (no associative arrays: the
# system /bin/bash on this machine is 3.2, which lacks them). Hyphens in
# host names are mapped to underscores to form a valid variable name.
resolved_addr_var() {
    printf 'RESOLVED_ADDR_%s' "$(printf '%s' "$1" | tr '-' '_')"
}
set_resolved_addr() {
    local var
    var="$(resolved_addr_var "$1")"
    printf -v "${var}" '%s' "$2"
}
get_resolved_addr() {
    local var
    var="$(resolved_addr_var "$1")"
    printf '%s' "${!var:-}"
}

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

RESULT_LINES=()

record() {
    local status="$1" line="$2"
    case "${status}" in
        PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
        FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
        SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
    esac
    RESULT_LINES+=("${line}")
}

# --- name resolution -------------------------------------------------------

# Resolve a bare host name via dscacheutil and echo the first ip_address, or
# nothing if it did not resolve. Never aborts the caller on failure.
resolve_host() {
    local host="$1"
    local output
    if ! output="$(dscacheutil -q host -a name "${host}" 2>/dev/null)"; then
        return 0
    fi
    printf '%s\n' "${output}" | awk '/^ip_address:/ {print $2; exit}'
}

check_name_resolution() {
    local host="$1"
    local addr
    addr="$(resolve_host "${host}")"
    set_resolved_addr "${host}" "${addr}"
    if [ -n "${addr}" ]; then
        record PASS "$(printf 'PASS  name       %-16s -> %s' "${host}" "${addr}")"
    else
        record FAIL "$(printf 'FAIL  name       %-16s -> did not resolve (no ip_address from dscacheutil)' "${host}")"
    fi
}

# --- service reachability ---------------------------------------------------

# Attempt a single TCP connect with a hard timeout, bounded regardless of
# how the underlying host responds (open/closed/filtered/unreachable).
# Requires 'nc -z -G <timeout>'. Measured on this machine's BSD nc
# (macOS): -G IS supported ('nc -h' lists '-G conntimo  Connection
# timeout in seconds') and DOES reliably bound the connect phase —
# 'nc -z -G 5' against a black-holed address (192.0.2.1, TEST-NET-1)
# took ~5s and returned non-zero, against a refused port
# (127.0.0.1:9) returned non-zero in ~0s, and against a reachable
# open port returned 0 in ~0s. There is no /dev/tcp fallback: a
# bash-backgrounded '/dev/tcp' probe cannot distinguish a successful
# connect from a timeout-induced kill (the backgrounded subshell that
# opens the fd stays alive holding it even after connecting, so the
# timer's kill -9 reaps it either way and 'wait' returns 137 for both
# outcomes). Rather than ship that ambiguity, this script hard-requires
# nc -G support and fails loudly if it is absent.
#
# Returns 0 on a completed TCP handshake, 1 otherwise. Never hangs longer
# than roughly (timeout + 1)s.
NC_SUPPORTS_DASH_G=""
detect_nc_dash_g() {
    if [ -n "${NC_SUPPORTS_DASH_G}" ]; then
        return
    fi
    if command -v nc >/dev/null 2>&1 && nc -h 2>&1 | grep -q -- '-G '; then
        NC_SUPPORTS_DASH_G="yes"
    else
        NC_SUPPORTS_DASH_G="no"
    fi
}

require_nc_dash_g() {
    detect_nc_dash_g
    if [ "${NC_SUPPORTS_DASH_G}" != "yes" ]; then
        echo "ERROR: dns-verify.sh requires 'nc' with -G (connection timeout) support," >&2
        echo "       so service reachability checks can be bounded reliably. The 'nc'" >&2
        echo "       on this system ('$(command -v nc 2>/dev/null || echo "not found")') does not advertise -G in 'nc -h'." >&2
        echo "       There is no fallback probe: a bash /dev/tcp probe cannot distinguish" >&2
        echo "       a successful connect from a timeout, so this script refuses to run" >&2
        echo "       rather than silently report false results. Install/upgrade to a" >&2
        echo "       BSD nc that supports -G, or update PATH to point at one." >&2
        exit 1
    fi
}

tcp_connect() {
    local host="$1" port="$2" timeout="${3:-5}"
    nc -z -G "${timeout}" "${host}" "${port}" >/dev/null 2>&1
    return $?
}

check_service_any_port() {
    local host="$1" label="$2"
    shift 2
    local ports=("$@")
    local addr
    addr="$(get_resolved_addr "${host}")"

    if [ -z "${addr}" ]; then
        record FAIL "$(printf 'FAIL  service    %-16s %-24s -> name did not resolve (see name check above)' "${host}" "${label}")"
        return
    fi

    local port
    for port in "${ports[@]}"; do
        if tcp_connect "${host}" "${port}" 5; then
            record PASS "$(printf 'PASS  service    %-16s %-24s -> connected on port %s (%s)' "${host}" "${label}" "${port}" "${addr}")"
            return
        fi
    done

    local port_list
    port_list="$(IFS=,; echo "${ports[*]}")"
    record FAIL "$(printf 'FAIL  service    %-16s %-24s -> resolved to %s but connection refused/timed out on port(s) %s' "${host}" "${label}" "${addr}" "${port_list}")"
}

# --- staleness check ---------------------------------------------------------

env_override_var() {
    local host="$1" upper
    upper="$(printf '%s' "${host}" | tr '[:lower:]-' '[:upper:]_')"
    printf 'DNS_VERIFY_EXPECT_%s_OVERRIDE' "${upper}"
}

# Compare a resolved address against an expected address; pure function so
# it can be exercised directly without touching /etc/hosts. Echoes "same"
# or "stale" and returns non-zero on "stale" / empty inputs.
compare_staleness() {
    local resolved="$1" expected="$2"
    if [ -z "${resolved}" ] || [ -z "${expected}" ]; then
        printf 'unknown\n'
        return 2
    fi
    if [ "${resolved}" = "${expected}" ]; then
        printf 'same\n'
        return 0
    fi
    printf 'stale\n'
    return 1
}

TAILSCALE_STATUS_OUTPUT=""
TAILSCALE_STATUS_OK=0
fetch_tailscale_status() {
    local ts_bin="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    if [ -x "${ts_bin}" ]; then
        if TAILSCALE_STATUS_OUTPUT="$("${ts_bin}" status 2>/dev/null)"; then
            TAILSCALE_STATUS_OK=1
        fi
    elif command -v tailscale >/dev/null 2>&1; then
        if TAILSCALE_STATUS_OUTPUT="$(tailscale status 2>/dev/null)"; then
            TAILSCALE_STATUS_OK=1
        fi
    fi
}

tailscale_ip_for() {
    local host="$1"
    [ "${TAILSCALE_STATUS_OK}" -eq 1 ] || return 1
    printf '%s\n' "${TAILSCALE_STATUS_OUTPUT}" | awk -v h="${host}" '$2 == h {print $1; exit}'
}

check_staleness() {
    local host="$1"
    local resolved
    resolved="$(get_resolved_addr "${host}")"

    if [ "${TAILSCALE_STATUS_OK}" -ne 1 ]; then
        record SKIP "$(printf 'SKIP  staleness  %-16s -> tailscale status unavailable (Tailscale off or CLI not found)' "${host}")"
        return
    fi

    local override_var expected
    override_var="$(env_override_var "${host}")"
    expected="${!override_var:-}"
    if [ -z "${expected}" ]; then
        expected="$(tailscale_ip_for "${host}")"
    fi

    if [ -z "${expected}" ]; then
        record SKIP "$(printf 'SKIP  staleness  %-16s -> host not present in tailscale status output' "${host}")"
        return
    fi

    if [ -z "${resolved}" ]; then
        record SKIP "$(printf 'SKIP  staleness  %-16s -> cannot compare, name did not resolve' "${host}")"
        return
    fi

    local verdict
    verdict="$(compare_staleness "${resolved}" "${expected}")"
    case "${verdict}" in
        same)
            record PASS "$(printf 'PASS  staleness  %-16s -> matches live Tailscale IP (%s)' "${host}" "${resolved}")"
            ;;
        stale)
            record FAIL "$(printf 'FAIL  staleness  %-16s -> resolves to %s but live Tailscale IP is %s; check /etc/hosts or /etc/resolver/tailXXXX.ts.net' "${host}" "${resolved}" "${expected}")"
            ;;
        *)
            record SKIP "$(printf 'SKIP  staleness  %-16s -> could not compare (missing data)' "${host}")"
            ;;
    esac
}

# --- network state summary ---------------------------------------------------

network_state_summary() {
    local ts_state="down/unknown"
    if [ "${TAILSCALE_STATUS_OK}" -eq 1 ]; then
        ts_state="up"
    fi

    local nordvpn_state="absent"
    if ifconfig utun11 2>/dev/null | grep -q 'inet '; then
        nordvpn_state="present (utun11)"
    fi

    local home_lan_state="no"
    local en0_inet
    en0_inet="$(ifconfig en0 2>/dev/null | awk '/inet /{print $2; exit}')"
    if [ -n "${en0_inet}" ]; then
        case "${en0_inet}" in
            192.168.1.*) home_lan_state="yes (en0: ${en0_inet})" ;;
            *) home_lan_state="no (en0: ${en0_inet})" ;;
        esac
    fi

    printf 'State: tailscale=%s  nordvpn=%s  home-lan=%s\n' "${ts_state}" "${nordvpn_state}" "${home_lan_state}"
}

# --- main --------------------------------------------------------------------

require_nc_dash_g

fetch_tailscale_status

network_state_summary
echo

for h in "${HOSTS[@]}"; do
    check_name_resolution "${h}"
done

check_service_any_port streamy "synology-webui" 5000 5001
check_service_any_port mac-mini "ssh" 22

for h in "${HOSTS[@]}"; do
    check_staleness "${h}"
done

echo
for line in "${RESULT_LINES[@]}"; do
    printf '%s\n' "${line}"
done
echo
printf 'Summary: %d passed, %d failed, %d skipped\n' "${PASS_COUNT}" "${FAIL_COUNT}" "${SKIP_COUNT}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
    exit 1
fi
exit 0

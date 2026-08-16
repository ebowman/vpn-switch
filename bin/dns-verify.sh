#!/bin/bash
# dns-verify.sh — verify that the bare hostnames and services this repo cares
# about resolve and are reachable in the CURRENT network state.
#
# Usage: dns-verify.sh
#
# Prints a PASS/FAIL/SKIP table (one line per check) plus a leading network
# state summary, and exits non-zero if any check FAILs. SKIPs do not affect
# the exit code by themselves, EXCEPT that a missing 'nc -G' capability (see
# below) forces a non-zero exit even if the resulting checks only SKIP/PASS,
# since a required capability is missing. Read-only: no sudo, no config
# mutation.
#
# Intentionally does NOT use 'set -e' since probe commands are expected to
# fail without aborting the run — failures are data, not script errors.
#
# Name resolution and staleness checks run regardless of 'nc -G' support (no
# TCP capability is needed for them); only the TCP service-reachability
# checks are gated on 'nc -G' and SKIP (naming the missing capability, see
# nc_dash_g_skip_reason) rather than aborting the whole run if it is absent.
#
# NordVPN detection distinguishes the native IKEv2 profile (ipsec0, supported
# alongside Tailscale) from the NordVPN app's own tunnel (10.5.0.0/16 / DNS
# 100.64.0.2, UNSUPPORTED alongside Tailscale) via lib/nord-detect.sh's
# nord_mode. See that file for its own testing hook
# (NORD_DETECT_IFCONFIG_OVERRIDE / NORD_DETECT_SCUTIL_DNS_OVERRIDE).
#
# STATE-AWARE EXPECTATIONS (ADR-003, dns-config-j9y.3): the expected address
# for each bare host name depends on whether Tailscale is up or down --
#   - tailscale=up:   expect the live Tailscale (tailnet) IP (unchanged
#                      behaviour from before this bead).
#   - tailscale=down: expect the LAN IP from config/lan-hosts.conf (read via
#                      lib/lan-hosts.sh), the "LAN table". At home this
#                      should resolve via dnsmasq + the home.arpa search
#                      domain (see docs/hostnames/lan-dns.md); away, dnsmasq
#                      still answers the LAN address (a fast connection
#                      failure is the expected/correct outcome there, per
#                      ADR-003 -- this script does not attempt to
#                      distinguish home vs away).
# Staleness compares the resolved address against whichever table matches
# the current Tailscale state, and reports "matches LAN table" / "LAN table
# mismatch" (rather than "matches live Tailscale IP" / stale-vs-tailnet) when
# tailscale is down.
#
# Testing hooks:
#   - DNS_VERIFY_EXPECT_<HOST>_OVERRIDE (host name upper-cased, '-' -> '_')
#     forces the staleness check's expected address to an arbitrary value
#     regardless of which table would otherwise apply, so the FAIL path can
#     be exercised without mutating /etc/hosts or config/lan-hosts.conf. Not
#     used in normal operation.
#   - DNS_VERIFY_TAILSCALE_STATE_OVERRIDE=up|down forces which table
#     (tailnet vs LAN) this script treats as authoritative for BOTH the
#     resolution expectation note and the staleness comparison, without
#     actually toggling Tailscale -- lets the up/down expectation-switch
#     logic itself be unit-tested (see docs/hostnames/lan-dns.md) in a
#     single network state. It does NOT change what dscacheutil actually
#     resolves (that still reflects real system state); it only changes
#     which table this script compares against and how the State line's
#     tailscale=<..> value is derived for that comparison. Not used in
#     normal operation.

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

# Load the shared NordVPN mode detector (ikev2 vs app vs app+ikev2 vs
# absent). Degrade to nordvpn=unknown rather than aborting if it is missing.
NORD_DETECT_LIB="${REPO_ROOT}/lib/nord-detect.sh"
if [ -f "${NORD_DETECT_LIB}" ]; then
    # shellcheck source=lib/nord-detect.sh
    . "${NORD_DETECT_LIB}"
    NORD_DETECT_AVAILABLE=1
else
    NORD_DETECT_AVAILABLE=0
fi

# Load the LAN hosts table (ADR-003): config/lan-hosts.conf via
# lib/lan-hosts.sh's lan_hosts_lan_ip / lan_hosts_tailnet_ip. Degrade rather
# than abort if missing -- the LAN-table expectation/staleness checks below
# SKIP (naming the reason) if this library is unavailable.
LAN_HOSTS_LIB="${REPO_ROOT}/lib/lan-hosts.sh"
if [ -f "${LAN_HOSTS_LIB}" ]; then
    # shellcheck source=lib/lan-hosts.sh
    . "${LAN_HOSTS_LIB}"
    LAN_HOSTS_AVAILABLE=1
else
    LAN_HOSTS_AVAILABLE=0
fi

# Load lib/lan-dns.sh for its shared lan_dns_status probe (dns-config-j9y.3:
# this script and bin/vpn-ctl.sh now share one implementation rather than
# each keeping their own copy of the direct-probe logic). Degrade to
# reporting "not-installed" for the State line's lan-dns= token if missing.
LAN_DNS_LIB="${REPO_ROOT}/lib/lan-dns.sh"
if [ -f "${LAN_DNS_LIB}" ]; then
    # shellcheck source=lib/lan-dns.sh
    . "${LAN_DNS_LIB}"
    LAN_DNS_LIB_AVAILABLE=1
else
    LAN_DNS_LIB_AVAILABLE=0
fi

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
        return
    fi

    # No answer at all. With Tailscale down, this is the expected failure
    # mode until the two one-time root steps (ADR-003) are applied -- name
    # the likely cause explicitly rather than leaving the human to guess
    # (see docs/hostnames/lan-dns.md).
    if [ "$(dns_verify_effective_tailscale_state)" = "down" ]; then
        record FAIL "$(printf 'FAIL  name       %-16s -> no answer — the home.arpa search suffix is not being applied. Check: (1) /etc/resolver/home.arpa installed? (2) NordVPN IKEv2 profile regenerated WITH the DNS block and reinstalled? (3) home.arpa in Wi-Fi search domains? See docs/hostnames/lan-dns.md' "${host}")"
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
# outcomes). Rather than ship that ambiguity, the TCP service checks below
# require nc -G support and SKIP (naming the missing capability) rather than
# probing unreliably if it is absent -- see nc_dash_g_skip_reason.
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

# Reason string for SKIPping the TCP service checks when nc lacks -G. Empty
# when nc -G is supported (the normal path).
nc_dash_g_skip_reason() {
    detect_nc_dash_g
    if [ "${NC_SUPPORTS_DASH_G}" != "yes" ]; then
        printf "nc ('%s') does not support -G (connection timeout); cannot bound a TCP probe reliably" \
            "$(command -v nc 2>/dev/null || echo "not found")"
        return
    fi
    printf ''
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
    local addr skip_reason

    skip_reason="$(nc_dash_g_skip_reason)"
    if [ -n "${skip_reason}" ]; then
        record SKIP "$(printf 'SKIP  service    %-16s %-24s -> %s' "${host}" "${label}" "${skip_reason}")"
        return
    fi

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

# dns_verify_effective_tailscale_state — "up" or "down", honoring
# DNS_VERIFY_TAILSCALE_STATE_OVERRIDE (testing hook, see header comment) if
# set to exactly "up" or "down"; otherwise derived from real
# TAILSCALE_STATUS_OK (fetch_tailscale_status must have already run). This is
# ONLY used to choose which table (tailnet vs LAN) the expectation/staleness
# checks compare against -- it does not change what dscacheutil actually
# resolves.
dns_verify_effective_tailscale_state() {
    case "${DNS_VERIFY_TAILSCALE_STATE_OVERRIDE:-}" in
        up|down)
            printf '%s\n' "${DNS_VERIFY_TAILSCALE_STATE_OVERRIDE}"
            return
            ;;
    esac
    if [ "${TAILSCALE_STATUS_OK}" -eq 1 ]; then
        printf 'up\n'
    else
        printf 'down\n'
    fi
}

# check_staleness — compare the resolved address for <host> against whichever
# table (tailnet IP when effective state is "up", LAN table from
# config/lan-hosts.conf when "down") applies, per ADR-003.
check_staleness() {
    local host="$1"
    local resolved
    resolved="$(get_resolved_addr "${host}")"

    local state
    state="$(dns_verify_effective_tailscale_state)"

    local override_var expected
    override_var="$(env_override_var "${host}")"
    expected="${!override_var:-}"

    if [ "${state}" = "up" ]; then
        if [ "${TAILSCALE_STATUS_OK}" -ne 1 ] && [ -z "${expected}" ]; then
            record SKIP "$(printf 'SKIP  staleness  %-16s -> tailscale status unavailable (Tailscale off or CLI not found)' "${host}")"
            return
        fi
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
        return
    fi

    # state == down: compare against the LAN table (ADR-003).
    if [ -z "${expected}" ]; then
        if [ "${LAN_HOSTS_AVAILABLE}" -ne 1 ]; then
            record SKIP "$(printf 'SKIP  staleness  %-16s -> lib/lan-hosts.sh unavailable, cannot load LAN table' "${host}")"
            return
        fi
        expected="$(lan_hosts_lan_ip "${host}")"
    fi

    if [ -z "${expected}" ]; then
        record SKIP "$(printf 'SKIP  staleness  %-16s -> host not present in config/lan-hosts.conf' "${host}")"
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
            record PASS "$(printf 'PASS  staleness  %-16s -> matches LAN table (%s)' "${host}" "${resolved}")"
            ;;
        stale)
            record FAIL "$(printf 'FAIL  staleness  %-16s -> resolves to %s but LAN table says %s; LAN table mismatch -- check config/lan-hosts.conf or DHCP' "${host}" "${resolved}" "${expected}")"
            ;;
        *)
            record SKIP "$(printf 'SKIP  staleness  %-16s -> could not compare (missing data)' "${host}")"
            ;;
    esac
}

# --- lan-dns probe (ADR-003) --------------------------------------------------
#
# lan_dns_probe_state — print "answering", "not-answering", or
# "not-installed" for the dnsmasq LaunchAgent bin/lan-dns-install.sh sets up.
# Thin wrapper over lib/lan-dns.sh's lan_dns_status (dns-config-j9y.3: moved
# there so this script and bin/vpn-ctl.sh share one implementation). Degrades
# to "not-installed" if lib/lan-dns.sh itself could not be loaded, since that
# is this script's own conservative default when a dependency is missing.
lan_dns_probe_state() {
    if [ "${LAN_DNS_LIB_AVAILABLE}" -eq 1 ]; then
        lan_dns_status
        return
    fi
    printf 'not-installed\n'
}

# --- network state summary ---------------------------------------------------

NORD_MODE_RAW=""
NORD_MODE_BARE=""
compute_nord_mode() {
    if [ "${NORD_DETECT_AVAILABLE}" -eq 1 ]; then
        NORD_MODE_RAW="$(nord_mode)"
    else
        NORD_MODE_RAW="unknown"
    fi
    # Strip any "(iface)" suffix to get the bare word (ikev2/app/app+ikev2/
    # absent/unknown) for exit-code and check-row logic.
    NORD_MODE_BARE="${NORD_MODE_RAW%%(*}"
}

network_state_summary() {
    local ts_state="down/unknown"
    if [ "${TAILSCALE_STATUS_OK}" -eq 1 ]; then
        ts_state="up"
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

    local lan_dns_state
    lan_dns_state="$(lan_dns_probe_state)"

    printf 'State: tailscale=%s  nordvpn=%s  home-lan=%s  lan-dns=%s\n' "${ts_state}" "${NORD_MODE_RAW}" "${home_lan_state}" "${lan_dns_state}"
}

# WARN row + FAIL: the NordVPN app tunnel colliding with Tailscale's
# 100.64/10 range is the known-broken configuration (100.64.0.2 vs the
# tailnet). Counts as a FAIL so the exit code reflects the broken state.
check_nord_app_tailscale_collision() {
    case "${NORD_MODE_BARE}" in
        app|app+ikev2) : ;;
        *) return ;;
    esac
    if [ "${TAILSCALE_STATUS_OK}" -ne 1 ]; then
        return
    fi
    record FAIL "WARN  nordvpn    app-tunnel present with tailscale up -- unsupported (100.64.0.2 collides with 100.64/10)"
}

# --- main --------------------------------------------------------------------

fetch_tailscale_status
compute_nord_mode

network_state_summary
echo

# Name resolution and staleness checks need no TCP capability at all, so run
# them regardless of nc -G support: a machine lacking it still gets real DNS
# diagnostics instead of an early abort (only the TCP service checks below
# are gated on nc -G, and they degrade to SKIP rather than aborting the run).
for h in "${HOSTS[@]}"; do
    check_name_resolution "${h}"
done

check_service_any_port streamy "synology-webui" 5000 5001
check_service_any_port mac-mini "ssh" 22

for h in "${HOSTS[@]}"; do
    check_staleness "${h}"
done

check_nord_app_tailscale_collision

echo
for line in "${RESULT_LINES[@]}"; do
    printf '%s\n' "${line}"
done
echo
printf 'Summary: %d passed, %d failed, %d skipped\n' "${PASS_COUNT}" "${FAIL_COUNT}" "${SKIP_COUNT}"

# A missing nc -G is a required-capability gap, not merely a SKIP: force a
# non-zero exit even if every individual check happened to PASS/SKIP.
NC_DASH_G_MISSING=0
if [ -n "$(nc_dash_g_skip_reason)" ]; then
    NC_DASH_G_MISSING=1
    echo "Note: TCP service checks were SKIPped ('nc -G' unavailable); exiting non-zero because that capability is required for a complete run." >&2
fi

if [ "${NC_DASH_G_MISSING}" -eq 1 ]; then
    exit 1
fi

if [ "${FAIL_COUNT}" -gt 0 ]; then
    exit 1
fi
exit 0

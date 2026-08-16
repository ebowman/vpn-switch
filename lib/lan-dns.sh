#!/bin/bash
# lan-dns.sh -- sourceable functions that render the state-dependent
# home.arpa hosts file dnsmasq answers from, and keep it in sync with
# Tailscale's up/down state (dns-config-j9y.3, ADR-003 REFINED DESIGN R2).
#
# Usage:
#   source lib/lan-dns.sh
#   lan_dns_render up      # write the hosts file with TAILNET IPs, HUP dnsmasq
#   lan_dns_render down    # write the hosts file with LAN IPs, HUP dnsmasq
#   lan_dns_sync           # decide up/down from ts_state and render
#   lan_dns_status          # "answering" / "not-answering" / "not-installed"
#
# This file has NO side effects when sourced beyond resolving paths: it only
# defines functions and constants. Sourcing it does not write, read, or HUP
# anything -- only calling the functions above does.
#
# Depends on (sourced by the caller, or by this file if not already loaded):
#   - lib/lan-hosts.sh   (lan_hosts_lan_ip / lan_hosts_tailnet_ip / lan_hosts_names)
#   - lib/tailscale-ctl.sh (ts_state, for lan_dns_sync's up/down decision)
#
# Rendered file: "$HOME/Library/Application Support/vpn-switch/home-arpa.hosts"
# in /etc/hosts format, one line per configured host:
#   "<ip> <name>.home.arpa"
# FQDN-ONLY -- deliberately no bare "<name>" second column. Measured
# (dns-config-j9y.3): dnsmasq's addn-hosts treats a bare-name column exactly
# like /etc/hosts and answers it for ANY unqualified query regardless of
# search-domain context (verified: a bare "streamy" line answered a bare
# "streamy" A query directly, an unwanted leak outside the home.arpa zone).
# Omitting the bare column and relying on dnsmasq's own 'domain-needed'
# config directive was verified instead: a bare query then correctly gets
# NXDOMAIN, and 'streamy.home.arpa' still resolves via the FQDN line, and a
# SIGHUP after editing the file (no restart) re-reads it (addn-hosts is
# SIGHUP-aware; host-record is not, which is why bin/lan-dns-install.sh
# switched the dnsmasq conf from host-record= to addn-hosts=).
#
# Address selection (dns-config-j9y.3 REFINED DESIGN, comment "REFINED
# DESIGN"):
#   up:   prefer the LIVE address from 'tailscale status --json'
#         (Peer[].TailscaleIPs[0], matched by Peer[].HostName
#         case-insensitively against the configured host name), falling back
#         to config/lan-hosts.conf's tailnet column (lan_hosts_tailnet_ip) if
#         the peer is absent or offline (no TailscaleIPs). Which source was
#         used is logged to stderr per host.
#   down: config/lan-hosts.conf's LAN column (lan_hosts_lan_ip).
#
# Repo conventions: set -u, no set -e (probe/render functions return
# non-zero on failure rather than aborting a sourcing caller -- this file is
# sourced by bin/vpn-ctl.sh, whose own callers must keep running across a
# failed render). Bash 3.2 compatible: no 'declare -A', no '${var,,}'.

set -u

# --- path resolution (case-guard pattern, matches lib/lan-hosts.sh) --------

if [ -z "${LAN_DNS_LIB_DIR:-}" ]; then
    _LAN_DNS_SH_SOURCE="${BASH_SOURCE[0]}"
    case "${_LAN_DNS_SH_SOURCE}" in
        */*) _LAN_DNS_SH_PARENT="${_LAN_DNS_SH_SOURCE%/*}" ;;
        *)   _LAN_DNS_SH_PARENT="." ;;
    esac
    if LAN_DNS_LIB_DIR="$(cd "${_LAN_DNS_SH_PARENT}" 2>/dev/null && pwd)"; then
        :
    else
        LAN_DNS_LIB_DIR="."
    fi
    unset _LAN_DNS_SH_SOURCE _LAN_DNS_SH_PARENT
fi

# Load lib/lan-hosts.sh if its functions are not already defined (a caller
# may have already sourced it).
if ! command -v lan_hosts_names >/dev/null 2>&1; then
    if [ -f "${LAN_DNS_LIB_DIR}/lan-hosts.sh" ]; then
        # shellcheck source=lib/lan-hosts.sh
        . "${LAN_DNS_LIB_DIR}/lan-hosts.sh"
    fi
fi

# Load lib/tailscale-ctl.sh if ts_state is not already defined (needed by
# lan_dns_sync and by the tailscale-status lookup in lan_dns_render).
if ! command -v ts_state >/dev/null 2>&1; then
    if [ -f "${LAN_DNS_LIB_DIR}/tailscale-ctl.sh" ]; then
        # shellcheck source=lib/tailscale-ctl.sh
        . "${LAN_DNS_LIB_DIR}/tailscale-ctl.sh"
    fi
fi

# --- constants ---------------------------------------------------------------

LAN_DNS_SUPPORT_DIR="${LAN_DNS_SUPPORT_DIR:-${HOME}/Library/Application Support/vpn-switch}"
LAN_DNS_HOSTS_FILE="${LAN_DNS_HOSTS_FILE:-${LAN_DNS_SUPPORT_DIR}/home-arpa.hosts}"
LAN_DNS_LAUNCH_AGENT_LABEL="ie.boboco.vpn-switch.lan-dns"
LAN_DNS_LAUNCH_AGENT_PLIST="${HOME}/Library/LaunchAgents/${LAN_DNS_LAUNCH_AGENT_LABEL}.plist"
LAN_DNS_PID_FILE="${LAN_DNS_PID_FILE:-${LAN_DNS_SUPPORT_DIR}/dnsmasq-home-arpa.pid}"
LAN_DNS_PROBE_ADDR="127.0.0.1"
LAN_DNS_PROBE_PORT=5354
LAN_DNS_PROBE_TIMEOUT="${LAN_DNS_PROBE_TIMEOUT:-2}"

# --- internal helpers ---------------------------------------------------------

# _lan_dns_pid -- print dnsmasq's pid, or nothing if it cannot be determined.
# Tries, in order: (1) the pid-file dnsmasq itself writes (LAN_DNS_PID_FILE,
# set via 'pid-file=' in the generated dnsmasq conf -- fast, no launchctl
# call), (2) 'launchctl print gui/<uid>/<label>' (works even if the pid-file
# is stale/missing, e.g. right after a fresh install before dnsmasq has
# written it).
_lan_dns_pid() {
    local pid
    if [ -r "${LAN_DNS_PID_FILE}" ]; then
        pid="$(cat "${LAN_DNS_PID_FILE}" 2>/dev/null)"
        case "${pid}" in
            ''|*[!0-9]*) pid="" ;;
        esac
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            printf '%s\n' "${pid}"
            return 0
        fi
    fi

    local gui_domain
    gui_domain="gui/$(id -u)"
    pid="$(launchctl print "${gui_domain}/${LAN_DNS_LAUNCH_AGENT_LABEL}" 2>/dev/null | awk -F' = ' '/^[[:space:]]*pid = /{print $2; exit}')"
    case "${pid}" in
        ''|*[!0-9]*) printf '' ; return 1 ;;
    esac
    printf '%s\n' "${pid}"
}

# _lan_dns_hup -- send SIGHUP to dnsmasq so it re-reads addn-hosts (does NOT
# restart it -- host-record required a restart; addn-hosts does not).
# Returns 0 on a successful signal delivery, 1 if the pid could not be
# determined or the signal failed. Logs which pid it signaled to stderr.
_lan_dns_hup() {
    local pid
    pid="$(_lan_dns_pid)"
    if [ -z "${pid}" ]; then
        echo "lan-dns: could not determine dnsmasq's pid -- not signaled (is the LaunchAgent loaded? bin/lan-dns-install.sh)" >&2
        return 1
    fi
    if kill -HUP "${pid}" 2>/dev/null; then
        echo "lan-dns: sent SIGHUP to dnsmasq (pid ${pid})" >&2
        return 0
    fi
    echo "lan-dns: SIGHUP to dnsmasq (pid ${pid}) failed" >&2
    return 1
}

# _lan_dns_tailnet_ip_live <name> -- print the live tailnet IP for <name>
# from 'tailscale status --json' (Peer[].TailscaleIPs[0], matched by
# Peer[].HostName case-insensitively), or nothing if unavailable (CLI
# missing/failed, or no matching peer with a TailscaleIPs entry). Bounded by
# TS_CTL_BIN/TS_CTL_CALL_TIMEOUT from lib/tailscale-ctl.sh if that library is
# loaded; otherwise falls back to a plain 'tailscale' on PATH, unbounded.
_lan_dns_tailnet_ip_live() {
    local name="${1:-}"
    [ -n "${name}" ] || return 1

    local ts_bin json
    ts_bin="${TS_CTL_BIN:-}"
    if [ -z "${ts_bin}" ] || { ! command -v "${ts_bin}" >/dev/null 2>&1 && [ ! -x "${ts_bin}" ]; }; then
        if command -v tailscale >/dev/null 2>&1; then
            ts_bin="tailscale"
        else
            return 1
        fi
    fi

    if command -v _ts_ctl_run_bounded >/dev/null 2>&1; then
        json="$(_ts_ctl_run_bounded "${ts_bin}" status --json 2>/dev/null)"
    else
        json="$("${ts_bin}" status --json 2>/dev/null)"
    fi
    [ -n "${json}" ] || return 1

    # Minimal JSON extraction (no jq dependency, matches ts_state's own
    # awk-based approach): find the Peer object whose HostName matches
    # (case-insensitively) <name>, then that same object's first
    # TailscaleIPs entry. Self is included too, since a host name could in
    # principle be this machine's own (not expected for streamy/
    # mac-mini, but harmless to support).
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "${json}" | python3 -c '
import json, sys
name = sys.argv[1].lower()
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
candidates = list((d.get("Peer") or {}).values())
self_entry = d.get("Self")
if self_entry:
    candidates.append(self_entry)
for entry in candidates:
    hn = (entry.get("HostName") or "").lower()
    if hn == name:
        ips = entry.get("TailscaleIPs") or []
        if ips:
            print(ips[0])
            sys.exit(0)
sys.exit(1)
' "${name}"
        return $?
    fi

    # No python3: degrade to unavailable rather than guessing with a fragile
    # awk-based JSON parse (Tailscale's JSON is not line-oriented in a way
    # that is safe to parse with the ts_state-style single-key awk trick).
    return 1
}

# --- public: lan_dns_render ---------------------------------------------------

# lan_dns_render <up|down> -- write LAN_DNS_HOSTS_FILE (FQDN-only, one line
# per configured host: "<ip> <name>.home.arpa"), then HUP dnsmasq so it
# re-reads it. Returns 0 on success (file written AND dnsmasq signaled), 1 on
# any failure (bad argument, no hosts configured, could not write the file,
# or -- logged but non-fatal to the write itself -- could not signal
# dnsmasq). Logs to stderr which address source (live tailnet / conf
# fallback / LAN) was used for each host.
lan_dns_render() {
    local mode="${1:-}"
    case "${mode}" in
        up|down) ;;
        *)
            echo "lan-dns: lan_dns_render requires 'up' or 'down', got '${mode}'" >&2
            return 1
            ;;
    esac

    if ! command -v lan_hosts_names >/dev/null 2>&1; then
        echo "lan-dns: lib/lan-hosts.sh not loaded -- cannot render" >&2
        return 1
    fi

    if ! mkdir -p "${LAN_DNS_SUPPORT_DIR}"; then
        echo "lan-dns: could not create ${LAN_DNS_SUPPORT_DIR}" >&2
        return 1
    fi

    local tmp="${LAN_DNS_HOSTS_FILE}.tmp.$$"
    local host_count=0
    {
        echo "# Generated by lib/lan-dns.sh (lan_dns_render ${mode}) -- DO NOT EDIT."
        echo "# Source: config/lan-hosts.conf. See docs/hostnames/lan-dns.md."
        local name ip source
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            ip=""
            source=""
            if [ "${mode}" = "up" ]; then
                ip="$(_lan_dns_tailnet_ip_live "${name}")"
                if [ -n "${ip}" ]; then
                    source="live tailscale status"
                else
                    ip="$(lan_hosts_tailnet_ip "${name}")"
                    source="config/lan-hosts.conf tailnet column (fallback: no live peer)"
                fi
            else
                ip="$(lan_hosts_lan_ip "${name}")"
                source="config/lan-hosts.conf LAN column"
            fi

            if [ -z "${ip}" ]; then
                echo "lan-dns: no ${mode} address available for '${name}' -- skipped" >&2
                continue
            fi

            echo "lan-dns: ${name} -> ${ip} (${source})" >&2
            echo "${ip} ${name}.home.arpa"
            host_count=$((host_count + 1))
        done < <(lan_hosts_names)
    } >"${tmp}"

    if [ "${host_count}" -eq 0 ]; then
        echo "lan-dns: no hosts rendered (config/lan-hosts.conf empty or unreadable, or no addresses available) -- not installing" >&2
        rm -f "${tmp}"
        return 1
    fi

    if ! mv "${tmp}" "${LAN_DNS_HOSTS_FILE}"; then
        echo "lan-dns: failed to install ${LAN_DNS_HOSTS_FILE}" >&2
        rm -f "${tmp}"
        return 1
    fi

    _lan_dns_hup
    return 0
}

# --- public: lan_dns_sync ------------------------------------------------------

# lan_dns_sync -- decide up/down from ts_state (lib/tailscale-ctl.sh) and
# call lan_dns_render accordingly. "Running" -> up; anything else (Stopped,
# NeedsLogin, Starting, Unknown, ...) -> down (the safe default: LAN
# addresses at least resolve at home, and a stale tailnet answer is worse
# than a LAN one while Tailscale is not confirmed Running). Returns
# lan_dns_render's exit status; 1 if ts_state itself is unavailable.
lan_dns_sync() {
    if ! command -v ts_state >/dev/null 2>&1; then
        echo "lan-dns: lib/tailscale-ctl.sh not loaded -- cannot determine up/down, defaulting to down" >&2
        lan_dns_render down
        return $?
    fi

    local state
    state="$(ts_state)"
    if [ "${state}" = "Running" ]; then
        lan_dns_render up
        return $?
    fi
    lan_dns_render down
    return $?
}

# --- public: lan_dns_status ----------------------------------------------------

# lan_dns_status -- print "answering", "not-answering", or "not-installed"
# for the dnsmasq LaunchAgent bin/lan-dns-install.sh sets up. Moved here from
# bin/vpn-ctl.sh / bin/dns-verify.sh (dns-config-j9y.3) so both callers share
# one implementation; those callers now delegate to this function.
#
# "not-installed": the LaunchAgent plist is absent (never installed, or
# uninstalled).
# "not-answering": the plist exists but a direct UDP probe of
# 127.0.0.1:5354 got no response within LAN_DNS_PROBE_TIMEOUT seconds (2s
# default), or 'dig' is unavailable.
# "answering": a direct query for the first configured host's home.arpa FQDN
# got a real response (positive or NXDOMAIN both count -- either means the
# server is up and answering; only a timeout means "not-answering").
#
# Probes 127.0.0.1:5354 DIRECTLY (a specific server), not the system
# resolver -- the documented exception to this project's "no dig" rule.
lan_dns_status() {
    if [ ! -f "${LAN_DNS_LAUNCH_AGENT_PLIST}" ]; then
        printf 'not-installed\n'
        return 0
    fi

    if ! command -v dig >/dev/null 2>&1; then
        printf 'not-answering\n'
        return 0
    fi

    local probe_name="streamy.home.arpa"
    if command -v lan_hosts_names >/dev/null 2>&1; then
        local first_host
        first_host="$(lan_hosts_names | head -1)"
        [ -n "${first_host}" ] && probe_name="${first_host}.home.arpa"
    fi

    if dig "+time=${LAN_DNS_PROBE_TIMEOUT}" +tries=1 \
        "@${LAN_DNS_PROBE_ADDR}" -p "${LAN_DNS_PROBE_PORT}" "${probe_name}" A >/dev/null 2>&1; then
        printf 'answering\n'
    else
        printf 'not-answering\n'
    fi
    return 0
}

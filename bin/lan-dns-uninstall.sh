#!/bin/bash
# lan-dns-uninstall.sh -- removes the ADR-003 (option C) LAN-fallback
# dnsmasq LaunchAgent and its generated config/logs. NO sudo -- ever.
#
# Usage:
#   bin/lan-dns-uninstall.sh
#
# What this removes:
#   - unloads (bootout) and deletes
#     "$HOME/Library/LaunchAgents/ie.boboco.vpn-switch.lan-dns.plist"
#   - the generated dnsmasq conf/log/stdout/stderr files under
#     "$HOME/Library/Application Support/vpn-switch/"
#
# What this deliberately does NOT do:
#   - remove config/lan-hosts.conf (repo source file, not installed state)
#   - run 'brew uninstall dnsmasq' (printed as an optional step, never run)
#   - undo the two root steps (printed, never run -- see below)
#
# Idempotent: safe to re-run; reports "not present" rather than failing for
# anything already removed.
#
# Repo conventions: set -u, no set -e, case-guard BASH_SOURCE resolution,
# bash 3.2 compatible. No sudo.

set -u

case "${BASH_SOURCE[0]}" in
    */*) SCRIPT_PARENT="${BASH_SOURCE[0]%/*}" ;;
    *)   SCRIPT_PARENT="." ;;
esac
if ! REPO_ROOT="$(cd "${SCRIPT_PARENT}/.." 2>/dev/null && pwd)"; then
    echo "lan-dns-uninstall: could not resolve repo root" >&2
    exit 1
fi
: "${REPO_ROOT}"

SUPPORT_DIR="${HOME}/Library/Application Support/vpn-switch"
DNSMASQ_CONF="${SUPPORT_DIR}/dnsmasq-home-arpa.conf"
DNSMASQ_LOG="${SUPPORT_DIR}/dnsmasq-home-arpa.log"
DNSMASQ_PID_FILE="${SUPPORT_DIR}/dnsmasq-home-arpa.pid"
LAUNCH_AGENT_LABEL="ie.boboco.vpn-switch.lan-dns"
LAUNCH_AGENT_PLIST="${HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
LAN_DNS_STDOUT="${SUPPORT_DIR}/lan-dns.stdout.log"
LAN_DNS_STDERR="${SUPPORT_DIR}/lan-dns.stderr.log"
LAN_DNS_HOSTS_FILE="${SUPPORT_DIR}/home-arpa.hosts"
RESOLVER_FILE="/etc/resolver/home.arpa"

echo "=== LAN DNS (home.arpa) uninstall ==="
echo

# --- step 1: unload the LaunchAgent -----------------------------------------

echo "==> [1/3] Unloading LaunchAgent"
GUI_DOMAIN="gui/$(id -u)"
if launchctl print "${GUI_DOMAIN}/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1; then
    if launchctl bootout "${GUI_DOMAIN}/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1; then
        echo "    unloaded"
    else
        echo "    warning: bootout failed (may already be unloading)" >&2
    fi
else
    echo "    not loaded"
fi
echo

# --- step 2: remove the plist and generated files ---------------------------

echo "==> [2/3] Removing installed files"
for _f in "${LAUNCH_AGENT_PLIST}" "${DNSMASQ_CONF}" "${DNSMASQ_LOG}" "${LAN_DNS_STDOUT}" "${LAN_DNS_STDERR}" "${LAN_DNS_HOSTS_FILE}" "${DNSMASQ_PID_FILE}"; do
    if [ -e "${_f}" ]; then
        if rm -f "${_f}"; then
            echo "    removed ${_f}"
        else
            echo "lan-dns-uninstall: failed to remove ${_f}" >&2
            exit 1
        fi
    else
        echo "    not present: ${_f}"
    fi
done
echo

# --- step 3: print the root-level undo (never run) ---------------------------

echo "==> [3/3] Root-level undo (this script does not and will not run these)"
echo
echo "    sudo rm ${RESOLVER_FILE}"
echo

_service_order="$(networksetup -listnetworkserviceorder 2>/dev/null)"
_services="$(printf '%s\n' "${_service_order}" | awk -F'^\\([0-9]+\\) ' '/^\([0-9]+\) /{print $2}')"
IFS=$'\n'
for _svc in ${_services}; do
    [ -n "${_svc}" ] || continue
    case "${_svc}" in
        '*'*) continue ;;
    esac
    _dev="$(printf '%s\n' "${_service_order}" | awk -v svc="${_svc}" '
        found==1 {
            if (match($0, /Device: [^)]*/)) {
                d = substr($0, RSTART+8, RLENGTH-8)
                print d
            }
            exit
        }
        $0 ~ ("^\\([0-9]+\\) " svc "$") { found=1 }
    ')"
    [ -n "${_dev}" ] || continue
    _ip="$(ipconfig getifaddr "${_dev}" 2>/dev/null)"
    [ -n "${_ip}" ] || continue

    _current="$(networksetup -getsearchdomains "${_svc}" 2>/dev/null)"
    case "${_current}" in
        *"There aren't any"*|"") continue ;;
    esac

    _has_home_arpa=0
    _without_list=""
    for _d in $(printf '%s\n' "${_current}" | tr ' ' '\n'); do
        [ -n "${_d}" ] || continue
        if [ "${_d}" = "home.arpa" ]; then
            _has_home_arpa=1
            continue
        fi
        if [ -z "${_without_list}" ]; then
            _without_list="${_d}"
        else
            _without_list="${_without_list} ${_d}"
        fi
    done

    if [ "${_has_home_arpa}" -eq 1 ]; then
        if [ -z "${_without_list}" ]; then
            echo "    sudo networksetup -setsearchdomains \"${_svc}\" Empty"
        else
            echo "    sudo networksetup -setsearchdomains \"${_svc}\" ${_without_list}"
        fi
    fi
done
unset IFS
echo

echo "Optional (not run): remove dnsmasq itself if nothing else on this machine uses it:"
echo "    brew uninstall dnsmasq"
echo
echo "Note: config/lan-hosts.conf in the repo is left in place -- it is source, not installed state."
echo
echo "=== Uninstall complete ==="

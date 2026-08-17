#!/bin/bash
# lan-dns-install.sh -- installs the ADR-003 (option C) LAN-fallback
# resolver: a user-level dnsmasq LaunchAgent, bound to 127.0.0.1:5354,
# authoritative for the home.arpa suffix, answering from
# config/lan-hosts.conf.
#
# See docs/adr-003-lan-fallback.md and docs/hostnames/lan-dns.md.
#
# Usage:
#   bin/lan-dns-install.sh
#
# What this installs (NO sudo -- ever):
#   - brew dnsmasq (installed if missing)
#   - "$HOME/Library/Application Support/vpn-switch/dnsmasq-home-arpa.conf"
#     (regenerated from config/lan-hosts.conf on every run)
#   - "$HOME/Library/LaunchAgents/ie.boboco.vpn-switch.lan-dns.plist"
#     (loaded via 'launchctl bootstrap gui/<uid>'; bootout+bootstrap if
#     already loaded, so config changes take effect)
#
# What this does NOT do -- the two remaining root steps are PRINTED, never
# run, at the end of this script (project rule: no sudo in scripts):
#   1. sudo mkdir -p /etc/resolver && printf '...' | sudo tee /etc/resolver/home.arpa
#   2. sudo networksetup -setsearchdomains <service> <existing...> home.arpa
#      (once per active network service that has an IP)
#
# Idempotent: safe to re-run. Regenerates the dnsmasq conf every time (so
# edits to config/lan-hosts.conf take effect), reloads the LaunchAgent, and
# detects+reports whether the two root steps are already done so a repeat
# run is quiet when everything is in place.
#
# Repo conventions: set -u, no set -e, case-guard BASH_SOURCE resolution,
# bash 3.2 compatible (no 'declare -A', no '${var,,}'). No sudo. No dig
# against the system resolver -- dig IS used here, once, as a DIRECT probe
# against 127.0.0.1:5354 (a specific server, not the system resolver), which
# is the one case this project's "no dig" rule exempts; see the probe step
# below for why.

set -u

case "${BASH_SOURCE[0]}" in
    */*) SCRIPT_PARENT="${BASH_SOURCE[0]%/*}" ;;
    *)   SCRIPT_PARENT="." ;;
esac
if ! REPO_ROOT="$(cd "${SCRIPT_PARENT}/.." 2>/dev/null && pwd)"; then
    echo "lan-dns-install: could not resolve repo root" >&2
    exit 1
fi

LAN_HOSTS_LIB="${REPO_ROOT}/lib/lan-hosts.sh"
if [ ! -f "${LAN_HOSTS_LIB}" ]; then
    echo "lan-dns-install: missing ${LAN_HOSTS_LIB}" >&2
    exit 1
fi
# shellcheck source=lib/lan-hosts.sh
. "${LAN_HOSTS_LIB}"

LAN_DNS_LIB="${REPO_ROOT}/lib/lan-dns.sh"
if [ ! -f "${LAN_DNS_LIB}" ]; then
    echo "lan-dns-install: missing ${LAN_DNS_LIB}" >&2
    exit 1
fi
# shellcheck source=lib/lan-dns.sh
. "${LAN_DNS_LIB}"

TS_CTL_LIB="${REPO_ROOT}/lib/tailscale-ctl.sh"
if [ ! -f "${TS_CTL_LIB}" ]; then
    echo "lan-dns-install: missing ${TS_CTL_LIB}" >&2
    exit 1
fi
# shellcheck source=lib/tailscale-ctl.sh
. "${TS_CTL_LIB}"

LAN_HOSTS_CONF="${REPO_ROOT}/config/lan-hosts.conf"
if [ ! -r "${LAN_HOSTS_CONF}" ]; then
    echo "lan-dns-install: missing ${LAN_HOSTS_CONF}" >&2
    exit 1
fi

SUPPORT_DIR="${HOME}/Library/Application Support/vpn-switch"
DNSMASQ_CONF="${SUPPORT_DIR}/dnsmasq-home-arpa.conf"
DNSMASQ_LOG="${SUPPORT_DIR}/dnsmasq-home-arpa.log"
DNSMASQ_PID_FILE="${LAN_DNS_PID_FILE}"
LAUNCH_AGENT_LABEL="ie.boboco.vpn-switch.lan-dns"
LAUNCH_AGENT_PLIST="${HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
LAN_DNS_PORT=5354
LAN_DNS_ADDR="127.0.0.1"
LAN_DNS_STDOUT="${SUPPORT_DIR}/lan-dns.stdout.log"
LAN_DNS_STDERR="${SUPPORT_DIR}/lan-dns.stderr.log"
LAN_DNS_ADDN_HOSTS="${LAN_DNS_HOSTS_FILE}"

echo "=== LAN DNS (home.arpa) install (ADR-003 option C) ==="
echo

# --- step 1: ensure dnsmasq is installed ------------------------------------

echo "==> [1/5] Ensuring dnsmasq is installed"
if brew list dnsmasq >/dev/null 2>&1; then
    echo "    already installed"
else
    echo "    installing via 'brew install dnsmasq'"
    if ! brew install dnsmasq; then
        echo "lan-dns-install: 'brew install dnsmasq' failed" >&2
        exit 1
    fi
fi

DNSMASQ_BIN=""
for candidate in /opt/homebrew/opt/dnsmasq/sbin/dnsmasq /usr/local/opt/dnsmasq/sbin/dnsmasq; do
    if [ -x "${candidate}" ]; then
        DNSMASQ_BIN="${candidate}"
        break
    fi
done
if [ -z "${DNSMASQ_BIN}" ] && command -v dnsmasq >/dev/null 2>&1; then
    DNSMASQ_BIN="$(command -v dnsmasq)"
fi
if [ -z "${DNSMASQ_BIN}" ]; then
    echo "lan-dns-install: could not locate dnsmasq binary after install" >&2
    exit 1
fi
echo "    binary: ${DNSMASQ_BIN}"
echo

# --- step 2: generate the dnsmasq conf --------------------------------------
#
# STATE-DEPENDENT ANSWERS (dns-config-j9y.3 REFINED DESIGN R2): dnsmasq no
# longer gets per-host 'host-record=' lines baked directly into this conf.
# Instead it reads an 'addn-hosts=' file (LAN_DNS_ADDN_HOSTS, rendered by
# lib/lan-dns.sh's lan_dns_render) that lib/lan-dns.sh regenerates and
# SIGHUPs dnsmasq for on every Tailscale up/down transition -- 'host-record'
# requires a full restart to pick up changes; 'addn-hosts' is re-read on
# SIGHUP (measured, dns-config-j9y.3). This conf file itself only changes
# when config/lan-hosts.conf's host LIST changes (add/remove a host) or on
# an explicit re-run of this installer -- not on every Tailscale toggle.
#
# NOTE: an EARLIER measurement on this bead (see the addn-hosts file's own
# header comment in lib/lan-dns.sh) found that a bare (unqualified) name
# column in an addn-hosts-style file answers bare queries directly, leaking
# outside the home.arpa zone. lib/lan-dns.sh's rendered file is therefore
# FQDN-only (one column: "<ip> <name>.home.arpa", no bare "<name>" column);
# 'domain-needed' below is what makes a bare unqualified query correctly get
# NXDOMAIN instead. 'expand-hosts' (which would synthesize a
# "<name>.<domain>" answer from a bare hosts-file entry using dnsmasq's own
# 'domain=' setting) is NOT needed here since the file already contains full
# home.arpa FQDNs -- there is nothing for expand-hosts to expand.

echo "==> [2/5] Generating dnsmasq config"
if ! mkdir -p "${SUPPORT_DIR}"; then
    echo "lan-dns-install: could not create ${SUPPORT_DIR}" >&2
    exit 1
fi

_host_count=0
while IFS= read -r _name; do
    [ -n "${_name}" ] || continue
    _host_count=$((_host_count + 1))
done < <(lan_hosts_names)
if [ "${_host_count}" -eq 0 ]; then
    echo "lan-dns-install: no hosts found in ${LAN_HOSTS_CONF}" >&2
    exit 1
fi

DNSMASQ_CONF_TMP="${DNSMASQ_CONF}.tmp.$$"
{
    echo "# Generated by bin/lan-dns-install.sh from config/lan-hosts.conf -- DO NOT EDIT."
    echo "# Regenerated on every install run. See docs/hostnames/lan-dns.md."
    echo "port=${LAN_DNS_PORT}"
    echo "listen-address=${LAN_DNS_ADDR}"
    echo "bind-interfaces"
    echo "no-resolv"
    echo "no-hosts"
    echo "no-poll"
    echo "local=/home.arpa/"
    echo "domain-needed"
    echo "bogus-priv"
    echo "addn-hosts=${LAN_DNS_ADDN_HOSTS}"
    echo "pid-file=${DNSMASQ_PID_FILE}"
    echo "log-facility=${DNSMASQ_LOG}"
} >"${DNSMASQ_CONF_TMP}"
if ! mv "${DNSMASQ_CONF_TMP}" "${DNSMASQ_CONF}"; then
    echo "lan-dns-install: failed to install ${DNSMASQ_CONF}" >&2
    rm -f "${DNSMASQ_CONF_TMP}"
    exit 1
fi
echo "    wrote ${DNSMASQ_CONF}"
echo "    hosts: $(lan_hosts_names | tr '\n' ' ')"
echo

# dnsmasq's 'addn-hosts=' file must exist before it starts (an absent file
# at startup is treated as an error by dnsmasq for addn-hosts, unlike a file
# that merely doesn't exist yet at HUP time) -- render an initial copy now,
# keyed off current Tailscale state, before the LaunchAgent (re)loads below.
# lan_dns_sync itself HUPs dnsmasq too, but that HUP is a harmless no-op
# here since dnsmasq is not running yet (or is about to be bounced by the
# bootout+bootstrap in step 3 regardless).
if ! lan_dns_sync; then
    echo "lan-dns-install: initial lan_dns_sync render failed -- continuing (LaunchAgent load may still fail if no hosts file exists)" >&2
fi
echo

# --- step 3: write and load the LaunchAgent ---------------------------------

echo "==> [3/5] Writing LaunchAgent"
if ! mkdir -p "${HOME}/Library/LaunchAgents"; then
    echo "lan-dns-install: could not create ${HOME}/Library/LaunchAgents" >&2
    exit 1
fi

PLIST_TMP="${LAUNCH_AGENT_PLIST}.tmp.$$"
cat >"${PLIST_TMP}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${DNSMASQ_BIN}</string>
        <string>--keep-in-foreground</string>
        <string>--conf-file=${DNSMASQ_CONF}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LAN_DNS_STDOUT}</string>
    <key>StandardErrorPath</key>
    <string>${LAN_DNS_STDERR}</string>
</dict>
</plist>
EOF
if ! mv "${PLIST_TMP}" "${LAUNCH_AGENT_PLIST}"; then
    echo "lan-dns-install: failed to install ${LAUNCH_AGENT_PLIST}" >&2
    rm -f "${PLIST_TMP}"
    exit 1
fi
echo "    wrote ${LAUNCH_AGENT_PLIST}"

GUI_DOMAIN="gui/$(id -u)"
if launchctl print "${GUI_DOMAIN}/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1; then
    echo "    already loaded -- bootout then bootstrap so config changes take effect"
    launchctl bootout "${GUI_DOMAIN}/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1
fi
if ! launchctl bootstrap "${GUI_DOMAIN}" "${LAUNCH_AGENT_PLIST}"; then
    echo "lan-dns-install: launchctl bootstrap failed" >&2
    exit 1
fi
echo "    loaded (${GUI_DOMAIN}/${LAUNCH_AGENT_LABEL})"
echo

# --- step 4: verify it is answering ------------------------------------------

echo "==> [4/5] Verifying dnsmasq is answering on ${LAN_DNS_ADDR}:${LAN_DNS_PORT}"
echo "    (probing the resolver DIRECTLY via 'dig @${LAN_DNS_ADDR} -p ${LAN_DNS_PORT}' --"
echo "    this project's 'no dig' rule is about the SYSTEM resolver; querying a"
echo "    specific server directly, as done here, is the documented exception.)"

_probe_ok=0
_probe_deadline=$(( $(date +%s) + 5 ))
while [ "$(date +%s)" -le "${_probe_deadline}" ]; do
    if command -v dig >/dev/null 2>&1; then
        _first_name="$(lan_hosts_names | head -1)"
        if [ -n "${_first_name}" ] && dig +short +time=1 +tries=1 "@${LAN_DNS_ADDR}" -p "${LAN_DNS_PORT}" "${_first_name}.home.arpa" A >/dev/null 2>&1; then
            _probe_ok=1
            break
        fi
    fi
    sleep 0.5
done

if [ "${_probe_ok}" -eq 1 ]; then
    echo "    answering"
else
    echo "    warning: dnsmasq did not answer a probe query within 5s -- check ${LAN_DNS_STDERR} and ${DNSMASQ_LOG}" >&2
fi
echo

# Re-sync once dnsmasq is confirmed running (the earlier sync, before step 3,
# ran before the LaunchAgent bootstrap and only existed to give dnsmasq a
# file to start with -- this one runs against the now-live process and is
# the authoritative render for this install run).
echo "    re-syncing hosts file against current Tailscale state"
if ! lan_dns_sync; then
    echo "lan-dns-install: lan_dns_sync failed after LaunchAgent load" >&2
fi
echo

# --- step 5: detect-and-report the two root steps ---------------------------

echo "==> [5/5] Root-step status (detect only; these steps are never run by this script)"

RESOLVER_FILE="/etc/resolver/home.arpa"
RESOLVER_EXPECTED="nameserver ${LAN_DNS_ADDR}
port ${LAN_DNS_PORT}"
if [ -f "${RESOLVER_FILE}" ] && [ "$(cat "${RESOLVER_FILE}" 2>/dev/null)" = "${RESOLVER_EXPECTED}" ]; then
    echo "    ${RESOLVER_FILE}: present and correct"
    RESOLVER_DONE=1
elif [ -f "${RESOLVER_FILE}" ]; then
    echo "    ${RESOLVER_FILE}: present but contents differ from expected -- re-run the command below"
    RESOLVER_DONE=0
else
    echo "    ${RESOLVER_FILE}: NOT present -- run the command below"
    RESOLVER_DONE=0
fi

echo
echo "One-time root steps (this script does not and will not run these):"
echo
printf '    sudo mkdir -p /etc/resolver && printf '"'"'nameserver %s\\nport %s\\n'"'"' | sudo tee %s\n' \
    "${LAN_DNS_ADDR}" "${LAN_DNS_PORT}" "${RESOLVER_FILE}"
echo

# Detect active network services (those with an assigned IPv4 address) and,
# for each, print the exact 'networksetup -setsearchdomains' command with
# home.arpa appended to whatever is already configured -- idempotent: if
# home.arpa is already present, report it and don't reprint a redundant add.
SEARCH_DOMAIN_STEPS_NEEDED=0
_service_order="$(networksetup -listnetworkserviceorder 2>/dev/null)"
# Parse "(n) Service Name" lines, paired with the following "(Hardware
# Port: ..., Device: <dev>)" line, to get each service's BSD device name.
_services="$(printf '%s\n' "${_service_order}" | awk -F'^\\([0-9]+\\) ' '/^\([0-9]+\) /{print $2}')"
IFS=$'\n'
for _svc in ${_services}; do
    [ -n "${_svc}" ] || continue
    # Skip disabled services (leading '*' in the numbered line -- rare, but
    # -listnetworkserviceorder marks them; our awk above already stripped
    # the "(n) " prefix so check the raw output for this service's line).
    case "${_svc}" in
        '*'*) continue ;;
    esac
    # Find the "(N) <svc>" line, then extract "Device: X" from the next line.
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
    _dropped_local=0
    case "${_current}" in
        *"There aren't any"*|"")
            _new_list="home.arpa"
            _already=0
            ;;
        *)
            _already=0
            _new_list=""
            IFS=$'\n'
            for _d in $(printf '%s\n' "${_current}" | tr ' ' '\n'); do
                [ -n "${_d}" ] || continue
                if [ "${_d}" = "home.arpa" ]; then
                    _already=1
                fi
                # 'local' is the mDNS zone: as a search suffix it makes bare
                # names wait on .local timing when this service is primary
                # (measured 2026-08-17: ~5.3s mDNS delay before falling
                # through to home.arpa). Never carry it forward.
                if [ "${_d}" = "local" ]; then
                    _dropped_local=1
                    continue
                fi
                if [ -z "${_new_list}" ]; then
                    _new_list="${_d}"
                else
                    _new_list="${_new_list} ${_d}"
                fi
            done
            if [ "${_already}" -eq 0 ]; then
                _new_list="${_new_list} home.arpa"
            fi
            ;;
    esac

    if [ "${_already}" -eq 1 ] && [ "${_dropped_local}" -eq 0 ]; then
        echo "    search domains for '${_svc}' (${_dev}, ${_ip}): home.arpa already present -- nothing to do"
    else
        echo "    search domains for '${_svc}' (${_dev}, ${_ip}):"
        echo "        sudo networksetup -setsearchdomains \"${_svc}\" ${_new_list}"
        if [ "${_dropped_local}" -eq 1 ]; then
            echo "        # note: dropped 'local' from the list -- it is the mDNS zone; as a search suffix it makes bare names wait on .local timing when this service is primary"
        fi
        SEARCH_DOMAIN_STEPS_NEEDED=1
    fi
done
unset IFS
echo

if [ "${RESOLVER_DONE}" -eq 1 ] && [ "${SEARCH_DOMAIN_STEPS_NEEDED}" -eq 0 ]; then
    echo "    Both root steps already applied -- nothing further needed."
    echo
fi

echo "Verify after applying the root steps above:"
echo "    scutil --dns | grep -A3 home.arpa"
echo "    dscacheutil -q host -a name streamy      # (with Tailscale off)"
echo
echo "=== Done ==="

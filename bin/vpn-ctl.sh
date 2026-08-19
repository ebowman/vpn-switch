#!/bin/bash
# vpn-ctl.sh — independent on/off/status control for NordVPN (native IKEv2
# profile) and Tailscale, verified by reality via lib/nord-ctl.sh and
# lib/tailscale-ctl.sh.
#
# Usage:
#   bin/vpn-ctl.sh nord on|off|status
#   bin/vpn-ctl.sh tailscale on|off|status
#   bin/vpn-ctl.sh lan-dns sync|status
#   bin/vpn-ctl.sh all off
#   bin/vpn-ctl.sh status
#
# 'status' (bare, or either subcommand's 'status' action) prints ONE
# machine-readable line:
#   nord=<up|down|app|app+ikev2|unknown> ts=<Running|Stopped|NeedsLogin|...> web=<ok|fail> streamy=<addr|fail> lan-dns=<answering|not-answering|not-installed>
#
# lan-dns=<..> (ADR-003, dns-config-j9y.3) reports the state of the user
# LaunchAgent dnsmasq resolver bin/lan-dns-install.sh sets up: "not-installed"
# if its LaunchAgent plist is absent, "not-answering" if the plist exists but
# a direct probe of 127.0.0.1:5354 got no response, "answering" otherwise.
# Appended at the END of the status line -- backward compatible: callers
# (the app's VPNStatus.parse) ignore unrecognized key=value tokens by
# design, so this addition does not require an app rebuild. Reported via
# lib/lan-dns.sh's lan_dns_status (shared with bin/dns-verify.sh).
#
# 'lan-dns sync' (dns-config-j9y.3 REFINED DESIGN R2) re-renders the
# state-dependent home.arpa hosts file dnsmasq answers from (tailnet IPs when
# Tailscale is up, LAN IPs when down) and SIGHUPs dnsmasq. 'tailscale
# on'/'tailscale off' below call this automatically after a successful
# transition; 'lan-dns sync' exists as a standalone subcommand for external
# callers that observe a Tailscale state change some other way (e.g. a
# polling app) without going through this script's own tailscale on/off --
# see the follow-up bead filed for wiring the VPN Switch app's poll loop to
# call it. 'lan-dns status' prints lan_dns_status's single-word result
# (answering/not-answering/not-installed) and always exits 0 (read-only,
# matches the bare 'status' subcommand's philosophy).
#
# Rules:
#   - The two toggles (nord, tailscale) are independent: neither implicitly
#     disconnects the other. Coexistence (NordVPN IKEv2 + Tailscale) is
#     proven safe — see dns-config-qsk.10.
#   - Every on/off waits on REALITY via the libs (nord_wait_for /
#     ts_wait_for), never a status API alone, then verifies web=ok (curl
#     https://example.com, --max-time 7, 2xx/3xx treated as ok — tolerates
#     captive portals, matches bin/dns-watch.sh's convention).
#   - Idempotent: if the target is already in the requested state, the
#     command is a no-op — it still prints the status line and exits 0.
#   - Lock file (mkdir-based, bash 3.2 friendly): concurrent invocations
#     cannot interleave. A second invocation while the lock is held exits
#     non-zero fast (6) with a message; it does not wait for the lock.
#   - On any wait timeout, the status line is printed and the command exits
#     non-zero (1) — never leaves the caller guessing.
#   - Tailscale NeedsLogin is surfaced, never looped: exits 2 with
#     "Tailscale needs login: open the Tailscale menu bar app".
#   - DEADLOCK GUARD (the one remaining ordering rule): if nord_state is
#     "app" or "app+ikev2" (the NordVPN APP's own tunnel, not the IKEv2
#     profile this script controls), 'tailscale on' refuses to run at all
#     (exit 4) because the app's tunnel's 100.64.0.2 resolver collides with
#     Tailscale's own 100.64/10 range (see dns-config-qsk.10 / c15.8).
#   - 'all off' runs nord off then tailscale off sequentially, under a
#     single lock acquisition: tailscale off ALWAYS runs, even if nord off
#     fails, so a Nord failure never leaves Tailscale up. Its exit code is
#     the first non-zero of {nord off, tailscale off} (nord-first), or 0 if
#     both succeed.
#
# Exit codes:
#   0  requested state verified (or already in it — no-op)
#   1  timeout waiting for the requested state, or web verification failed
#   2  Tailscale NeedsLogin — human must log in via the menu bar app
#   3  a required NordVPN Shortcut ("NordVPN On" / "NordVPN Off") is missing
#   4  unsupported configuration: NordVPN app tunnel detected, refusing to
#      start Tailscale (deadlock guard)
#   5  usage error (bad/missing subcommand or action)
#   6  another vpn-ctl.sh invocation holds the lock
#
# Repo conventions: set -u, no set -e (matches lib/tailscale-ctl.sh,
# lib/nord-ctl.sh, bin/dns-watch.sh — probe/control commands are expected to
# fail without aborting the script). Bash 3.2 compatible: no 'declare -A',
# no '${var,,}'. No sudo. No dig.

set -u

case "${BASH_SOURCE[0]}" in
    */*) SCRIPT_PARENT="${BASH_SOURCE[0]%/*}" ;;
    *)   SCRIPT_PARENT="." ;;
esac
if ! REPO_ROOT="$(cd "${SCRIPT_PARENT}/.." 2>/dev/null && pwd)"; then
    echo "vpn-ctl: could not resolve repo root" >&2
    exit 5
fi

NORD_CTL_LIB="${REPO_ROOT}/lib/nord-ctl.sh"
TS_CTL_LIB="${REPO_ROOT}/lib/tailscale-ctl.sh"
LAN_DNS_LIB="${REPO_ROOT}/lib/lan-dns.sh"

if [ ! -f "${NORD_CTL_LIB}" ]; then
    echo "vpn-ctl: missing ${NORD_CTL_LIB} — cannot control/query NordVPN" >&2
    exit 5
fi
if [ ! -f "${TS_CTL_LIB}" ]; then
    echo "vpn-ctl: missing ${TS_CTL_LIB} — cannot control/query Tailscale" >&2
    exit 5
fi
if [ ! -f "${LAN_DNS_LIB}" ]; then
    echo "vpn-ctl: missing ${LAN_DNS_LIB} — cannot control/query the LAN DNS resolver" >&2
    exit 5
fi

# shellcheck source=lib/nord-ctl.sh
. "${NORD_CTL_LIB}"
# shellcheck source=lib/tailscale-ctl.sh
. "${TS_CTL_LIB}"
# shellcheck source=lib/lan-dns.sh
. "${LAN_DNS_LIB}"

# --- configuration -----------------------------------------------------

VPN_CTL_WEB_TIMEOUT="${VPN_CTL_WEB_TIMEOUT:-7}"
VPN_CTL_WAIT_TIMEOUT="${VPN_CTL_WAIT_TIMEOUT:-45}"
VPN_CTL_LOCKDIR="${VPN_CTL_LOCKDIR:-${REPO_ROOT}/.vpn-ctl.lock}"

# --- helpers -------------------------------------------------------------

# web_check — print "ok" or "fail" for a real HTTPS fetch. 2xx/3xx = ok
# (tolerates captive portals, matches bin/dns-watch.sh's WEB column).
vpn_ctl_web_check() {
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "${VPN_CTL_WEB_TIMEOUT}" https://example.com 2>/dev/null)"
    case "${code}" in
        2*|3*) echo "ok" ;;
        *)     echo "fail" ;;
    esac
}

# streamy_check — print streamy's resolved address, or "fail" if it does
# not resolve. Bounded so a dead resolver cannot hang the caller.
vpn_ctl_streamy_check() {
    local addr
    addr="$(timeout 5 dscacheutil -q host -a name streamy 2>/dev/null | awk '/ip_address/{print $2; exit}')"
    if [ -z "${addr}" ]; then
        echo "fail"
    else
        echo "${addr}"
    fi
}

# lan_dns_check — print "answering", "not-answering", or "not-installed" for
# the ADR-003 dnsmasq LaunchAgent (bin/lan-dns-install.sh). Thin wrapper over
# lib/lan-dns.sh's lan_dns_status (dns-config-j9y.3: moved there so this
# script and bin/dns-verify.sh share one implementation). Bounded to
# LAN_DNS_PROBE_TIMEOUT (2s default, set in lib/lan-dns.sh) so a
# hung/unreachable probe cannot stall 'vpn-ctl.sh status'.
vpn_ctl_lan_dns_check() {
    lan_dns_status
}

# status_line — build and print the one-line machine-readable status.
vpn_ctl_status_line() {
    local nord ts web streamy lan_dns
    nord="$(nord_state)"
    ts="$(ts_state)"
    web="$(vpn_ctl_web_check)"
    streamy="$(vpn_ctl_streamy_check)"
    lan_dns="$(vpn_ctl_lan_dns_check)"
    printf 'nord=%s ts=%s web=%s streamy=%s lan-dns=%s\n' "${nord}" "${ts}" "${web}" "${streamy}" "${lan_dns}"
}

# --- lock (mkdir-based, bash 3.2 friendly) --------------------------------
#
# mkdir is atomic even on network/legacy filesystems and needs no external
# lock utility (flock is not reliably present on macOS). The lock is held
# for the whole run and removed on exit via a trap, including on timeout
# and error paths.

VPN_CTL_LOCK_HELD=0

vpn_ctl_acquire_lock() {
    if mkdir "${VPN_CTL_LOCKDIR}" 2>/dev/null; then
        VPN_CTL_LOCK_HELD=1
        # Record who holds it: read back by the stale-lock check below, and
        # useful to a human debugging a stuck lock.
        { echo "pid=$$"; date 2>/dev/null; } >"${VPN_CTL_LOCKDIR}/owner" 2>/dev/null
        return 0
    fi
    # Lock exists. The menu bar app calls this script repeatedly, so a lock
    # left behind by a crashed/killed invocation must not wedge every later
    # toggle at exit 6. If the recorded owner pid is no longer alive, the
    # lock is stale: remove it and retry once. If there is no readable owner
    # pid we cannot tell, so we stay conservative and treat it as held.
    local owner_pid
    owner_pid="$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' "${VPN_CTL_LOCKDIR}/owner" 2>/dev/null | head -1)"
    if [ -n "${owner_pid}" ] && ! kill -0 "${owner_pid}" 2>/dev/null; then
        echo "vpn-ctl: removing stale lock left by dead pid ${owner_pid}" >&2
        rm -rf "${VPN_CTL_LOCKDIR}" 2>/dev/null
        if mkdir "${VPN_CTL_LOCKDIR}" 2>/dev/null; then
            VPN_CTL_LOCK_HELD=1
            { echo "pid=$$"; date 2>/dev/null; } >"${VPN_CTL_LOCKDIR}/owner" 2>/dev/null
            return 0
        fi
    fi
    return 1
}

vpn_ctl_release_lock() {
    if [ "${VPN_CTL_LOCK_HELD}" -eq 1 ]; then
        rm -rf "${VPN_CTL_LOCKDIR}" 2>/dev/null
        VPN_CTL_LOCK_HELD=0
    fi
}

# shellcheck disable=SC2329 # invoked indirectly via the EXIT trap below
vpn_ctl_cleanup() {
    vpn_ctl_release_lock
}
trap vpn_ctl_cleanup EXIT

# --- subcommands -----------------------------------------------------------

# do_nord_status — print the status line, no lock needed (read-only).
do_status() {
    vpn_ctl_status_line
    return 0
}

# do_nord_on — bring the NordVPN IKEv2 profile up.
do_nord_on() {
    if [ "$(nord_state)" = "up" ]; then
        vpn_ctl_status_line
        return 0
    fi

    nord_connect "${VPN_CTL_WAIT_TIMEOUT}"
    local rc=$?
    if [ "${rc}" -eq 3 ]; then
        # nord_connect already printed the shortcut-missing message on
        # stderr; still surface the status line so the caller can see
        # nothing changed.
        vpn_ctl_status_line
        return 3
    fi
    if [ "${rc}" -ne 0 ]; then
        vpn_ctl_status_line
        return 1
    fi

    if [ "$(vpn_ctl_web_check)" != "ok" ]; then
        vpn_ctl_status_line
        return 1
    fi

    vpn_ctl_status_line
    return 0
}

# do_nord_off — bring the NordVPN IKEv2 profile down.
do_nord_off() {
    if [ "$(nord_state)" = "down" ]; then
        vpn_ctl_status_line
        return 0
    fi

    nord_disconnect "${VPN_CTL_WAIT_TIMEOUT}"
    local rc=$?
    if [ "${rc}" -eq 3 ]; then
        vpn_ctl_status_line
        return 3
    fi
    if [ "${rc}" -ne 0 ]; then
        vpn_ctl_status_line
        return 1
    fi

    # No web check required after disconnecting Nord: LAN/other paths may
    # still be up or down independent of Nord, and the contract only
    # requires verifying web=ok after a successful transition INTO a
    # connected state. Still surface reality either way.
    vpn_ctl_status_line
    return 0
}

# do_tailscale_on — bring Tailscale up, honoring the deadlock guard.
do_tailscale_on() {
    local nord_now
    nord_now="$(nord_state)"
    case "${nord_now}" in
        app|app+ikev2)
            echo "NordVPN app tunnel detected (100.64.0.2 collides with Tailscale's 100.64/10) — disconnect the NordVPN app first; use the IKEv2 profile instead (docs/switcher/nord-ikev2-setup.md)" >&2
            vpn_ctl_status_line
            return 4
            ;;
    esac

    if [ "$(ts_state)" = "Running" ]; then
        vpn_ctl_status_line
        return 0
    fi

    ts_up
    if ! ts_wait_for Running "${VPN_CTL_WAIT_TIMEOUT}"; then
        if [ "$(ts_state)" = "NeedsLogin" ]; then
            echo "Tailscale needs login: open the Tailscale menu bar app" >&2
            vpn_ctl_status_line
            return 2
        fi
        vpn_ctl_status_line
        return 1
    fi

    if [ "$(ts_state)" = "NeedsLogin" ]; then
        echo "Tailscale needs login: open the Tailscale menu bar app" >&2
        vpn_ctl_status_line
        return 2
    fi

    # dns-config-j9y.3 REFINED DESIGN R2: re-render the state-dependent
    # home.arpa hosts file (now up -> tailnet IPs) after Tailscale has
    # settled into Running, before the web check.
    lan_dns_sync

    if [ "$(vpn_ctl_web_check)" != "ok" ]; then
        vpn_ctl_status_line
        return 1
    fi

    vpn_ctl_status_line
    return 0
}

# do_tailscale_off — bring Tailscale down.
do_tailscale_off() {
    if [ "$(ts_state)" = "Stopped" ]; then
        vpn_ctl_status_line
        return 0
    fi

    ts_down
    if ! ts_wait_for Stopped "${VPN_CTL_WAIT_TIMEOUT}"; then
        vpn_ctl_status_line
        return 1
    fi

    # dns-config-j9y.3 REFINED DESIGN R2: re-render the state-dependent
    # home.arpa hosts file (now down -> LAN IPs) after Tailscale has settled
    # into Stopped. No web check follows this state (see below), so this is
    # simply "post wait" here.
    lan_dns_sync

    # web=ok is verified after transitions INTO a connected state per the
    # contract; going to Stopped does not require it (bringing Tailscale
    # down should not fail the command merely because e.g. Nord is also
    # down and the LAN itself is offline for unrelated reasons). Reality is
    # still surfaced in the status line either way.
    vpn_ctl_status_line
    return 0
}

# do_all_off — composite: bring both Nord and Tailscale down. Runs
# do_tailscale_off UNCONDITIONALLY even if do_nord_off fails, so a Nord
# failure never leaves Tailscale up. On any failure, prints one summary
# line to stderr (the app surfaces the last non-empty stderr line on
# failure). Does not add its own status line: do_tailscale_off's final
# status line is already the last stdout status line.
do_all_off() {
    local nord_rc ts_rc

    do_nord_off
    nord_rc=$?

    do_tailscale_off
    ts_rc=$?

    if [ "${nord_rc}" -ne 0 ] || [ "${ts_rc}" -ne 0 ]; then
        local nord_summary ts_summary
        if [ "${nord_rc}" -eq 0 ]; then
            nord_summary="ok"
        else
            nord_summary="failed (exit ${nord_rc})"
        fi
        if [ "${ts_rc}" -eq 0 ]; then
            ts_summary="ok"
        else
            ts_summary="failed (exit ${ts_rc})"
        fi
        echo "vpn-ctl: all off: nord=${nord_summary} tailscale=${ts_summary}" >&2
    fi

    if [ "${nord_rc}" -ne 0 ]; then
        return "${nord_rc}"
    fi
    if [ "${ts_rc}" -ne 0 ]; then
        return "${ts_rc}"
    fi
    return 0
}

# do_lan_dns_sync — standalone 'lan-dns sync' subcommand: re-render the
# state-dependent home.arpa hosts file from current reality (ts_state) and
# HUP dnsmasq. See lib/lan-dns.sh's lan_dns_sync. Exists for callers that
# observe a Tailscale state change without going through this script's own
# 'tailscale on|off' (which already call lan_dns_sync internally).
do_lan_dns_sync() {
    if lan_dns_sync; then
        vpn_ctl_status_line
        return 0
    fi
    vpn_ctl_status_line
    return 1
}

# do_lan_dns_status — standalone 'lan-dns status' subcommand: print
# lan_dns_status's single word (answering/not-answering/not-installed).
# Read-only; always exits 0 (matches the bare 'status' subcommand).
do_lan_dns_status() {
    lan_dns_status
    return 0
}

# --- usage / dispatch --------------------------------------------------

usage() {
    cat >&2 <<'EOF'
Usage:
  vpn-ctl.sh nord on|off|status
  vpn-ctl.sh tailscale on|off|status
  vpn-ctl.sh lan-dns sync|status
  vpn-ctl.sh all off
  vpn-ctl.sh status
EOF
}

main() {
    if [ "$#" -eq 0 ]; then
        usage
        return 5
    fi

    local target="$1"
    local action="${2:-}"

    case "${target}" in
        status)
            if [ -n "${action}" ]; then
                usage
                return 5
            fi
            do_status
            return $?
            ;;
        nord)
            case "${action}" in
                status)
                    do_status
                    return $?
                    ;;
                on|off) ;; # fall through to locked section below
                *)
                    usage
                    return 5
                    ;;
            esac
            ;;
        tailscale)
            case "${action}" in
                status)
                    do_status
                    return $?
                    ;;
                on|off) ;; # fall through to locked section below
                *)
                    usage
                    return 5
                    ;;
            esac
            ;;
        lan-dns)
            case "${action}" in
                status)
                    do_lan_dns_status
                    return $?
                    ;;
                sync) ;; # fall through to locked section below
                *)
                    usage
                    return 5
                    ;;
            esac
            ;;
        all)
            case "${action}" in
                off) ;; # fall through to locked section below
                *)
                    usage
                    return 5
                    ;;
            esac
            ;;
        *)
            usage
            return 5
            ;;
    esac

    # Only on/off actions reach here; they mutate state and need the lock.
    if ! vpn_ctl_acquire_lock; then
        echo "vpn-ctl: another invocation holds the lock (${VPN_CTL_LOCKDIR}) — try again shortly" >&2
        return 6
    fi

    local rc
    case "${target}:${action}" in
        nord:on)       do_nord_on;       rc=$? ;;
        nord:off)      do_nord_off;      rc=$? ;;
        tailscale:on)  do_tailscale_on;  rc=$? ;;
        tailscale:off) do_tailscale_off; rc=$? ;;
        lan-dns:sync)  do_lan_dns_sync;  rc=$? ;;
        all:off)       do_all_off;       rc=$? ;;
        *)
            usage
            rc=5
            ;;
    esac

    vpn_ctl_release_lock
    return "${rc}"
}

main "$@"
exit $?

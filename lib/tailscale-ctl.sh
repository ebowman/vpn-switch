#!/bin/bash
# tailscale-ctl.sh — sourceable functions to control and query Tailscale.
#
# Usage:
#   source lib/tailscale-ctl.sh
#   ts_up                      # bring Tailscale up (tailscale up)
#   ts_down                    # bring Tailscale down (tailscale down)
#   ts_state                   # print current BackendState to stdout
#   ts_wait_for Running 30     # poll ts_state until it matches or 30s elapse
#
# This file has NO side effects when sourced: it only defines functions and
# a couple of read-only constants. It performs no mutation and issues no
# external calls at source time.
#
# Findings that motivate the choices below live in
# docs/switcher/tailscale-control.md (measured timings, settle times, and
# why ts_up/ts_down use 'tailscale up'/'tailscale down' rather than
# 'scutil --nc start/stop'):
#   - 'tailscale down' / 'tailscale up' never prompted for sudo in testing.
#   - 'scutil --nc stop "Tailscale 2"' (by UUID) reliably stops the tunnel,
#     as fast as 'tailscale down'.
#   - 'scutil --nc start "Tailscale 2"' (by UUID) is UNRELIABLE: it reports
#     scutil state "Connected" immediately but the tailscaled backend can
#     stay "Stopped" indefinitely (observed 15s+ with no progress) with no
#     route and no working DNS. Do not use scutil to bring Tailscale up.
#   - Because of that asymmetry, ts_up/ts_down both drive the 'tailscale'
#     CLI exclusively; scutil is not used by these functions at all.
#
# Every external call below is bounded by an explicit timeout so a hung
# tailscaled/scutil call cannot hang the caller. This file intentionally
# does NOT use 'set -e' (matches bin/dns-snapshot.sh and bin/dns-verify.sh):
# probe/control commands are expected to fail without aborting a caller
# that has sourced this library. Bash 3.2 compatible: no 'declare -A', no
# '${var,,}'.

set -u

# Path to the tailscale CLI. Prefer /usr/local/bin/tailscale: on this
# machine it is the wrapper that matches the running tailscaled daemon's
# version. A homebrew-installed 'tailscale' on PATH can be a different
# version and prints a "client != server version" warning on every call.
TS_CTL_BIN="${TS_CTL_BIN:-/usr/local/bin/tailscale}"

# Default per-call timeout (seconds) for 'tailscale up' / 'tailscale down'.
# Measured wall-clock in testing was ~0.4-1.2s; 15s gives ample margin
# without letting a hung daemon block the caller indefinitely.
TS_CTL_CALL_TIMEOUT="${TS_CTL_CALL_TIMEOUT:-15}"

# _vpn_run_bounded <seconds> <cmd...> — pure-shell bounded runner shared by
# lib/tailscale-ctl.sh and lib/nord-ctl.sh (dns-config-ci5 PART B: macOS has
# no /usr/bin/timeout, and Homebrew coreutils' gtimeout/timeout live under
# /opt/homebrew/bin, a group-admin-writable directory on this machine —
# resolving a bare 'timeout'/'gtimeout' via PATH is itself a hijack risk, so
# this vendors the bound instead of depending on either). Defined identically
# in both libs, guarded so sourcing both is harmless regardless of order.
#
# Runs "$@" in the background, starts a watchdog subshell that sleeps
# <seconds> then sends SIGTERM to the command's pid, and waits on the
# command. Returns 124 (GNU timeout's convention; callers already handle
# 124) if the watchdog fired before the command exited on its own, otherwise
# the command's real exit status. The watchdog is always killed and reaped
# immediately after the command's own `wait` returns, so no stray 'sleep'
# (or its file descriptors) is left running. stdout/stderr of the COMMAND
# are inherited directly (not touched by this function), so a caller's own
# "$(...)" capture works exactly as if the command had been run directly;
# the WATCHDOG subshell's own stdout/stderr are explicitly redirected to
# /dev/null so it never holds a caller's command-substitution pipe open
# (without this, `out="$(_vpn_run_bounded 5 cmd)"` would block until the
# watchdog itself exits, up to the full timeout, even after `cmd` finished
# immediately -- measured: turned a 0.37s `vpn-ctl.sh status` into 15.29s).
#
# CAUTION: SIGTERM is delivered only to the direct child's pid (the
# command run as "$@" itself), not to any process group -- a grandchild
# spawned and detached by that command (e.g. something `tailscale up` or
# `shortcuts run` forks internally) is NOT signalled by this function and
# can outlive it. The outer bound for that case is VPNCtl.swift's own
# process-group timeout/kill (POSIX_SPAWN_SETSID + kill(-pid, ...) after
# 60s), which this function's per-call timeout is deliberately tighter
# than but does not replace.
if ! declare -f _vpn_run_bounded >/dev/null 2>&1; then
_vpn_run_bounded() {
    local secs="$1"
    shift
    "$@" &
    local cmd_pid=$!
    # Flag file the watchdog creates iff it actually fires (i.e. the
    # command was still alive at the deadline), so the caller below can
    # distinguish "watchdog killed it" from "command exited on its own"
    # after both have been waited on. Named with both pids plus $$ so
    # concurrent _vpn_run_bounded calls (even nested) never collide.
    local timed_out_flag="${TMPDIR:-/tmp}/.vpn_run_bounded.$$.${cmd_pid}"
    rm -f "${timed_out_flag}" 2>/dev/null
    (
        sleep "${secs}"
        if kill -0 "${cmd_pid}" 2>/dev/null; then
            : >"${timed_out_flag}" 2>/dev/null
            kill -TERM "${cmd_pid}" 2>/dev/null
        fi
    ) >/dev/null 2>&1 &
    local watchdog_pid=$!

    local rc
    wait "${cmd_pid}"
    rc=$?

    # Watchdog no longer needed: kill and reap it immediately so no stray
    # sleep (or held-open descriptor) lingers, whether or not it fired.
    kill -TERM "${watchdog_pid}" 2>/dev/null
    wait "${watchdog_pid}" 2>/dev/null

    if [ -e "${timed_out_flag}" ]; then
        rm -f "${timed_out_flag}" 2>/dev/null
        return 124
    fi
    return "${rc}"
}
fi

# _ts_ctl_run_bounded — thin, name-compatible wrapper over the shared
# _vpn_run_bounded, bounded by TS_CTL_CALL_TIMEOUT. Returns the wrapped
# command's exit status (or 124 on timeout, matching GNU timeout's
# convention).
_ts_ctl_run_bounded() {
    _vpn_run_bounded "${TS_CTL_CALL_TIMEOUT}" "$@"
    return $?
}

# ts_up — bring Tailscale up via 'tailscale up'. No flags: an unflagged
# 'tailscale up' brings the network online without changing settings (the
# opposite of 'tailscale down') and does not require sudo. If the daemon
# needs re-authentication, 'tailscale up' will report NeedsLogin via
# ts_state after this call; callers must check ts_state rather than assume
# success from this function's exit code alone, since the underlying CLI
# can exit 0 while leaving BackendState at NeedsLogin (interactive login
# flow not completed).
#
# Returns: exit status of the 'tailscale up' call (0 on CLI success, 124 on
# timeout, nonzero on other CLI errors). Does not itself wait for the
# backend to settle -- use ts_wait_for after calling this.
ts_up() {
    _ts_ctl_run_bounded "${TS_CTL_BIN}" up
    return $?
}

# ts_down — bring Tailscale down via 'tailscale down'. No flags, no sudo
# required (observed in testing: 3/3 round-trips, no prompt).
#
# Returns: exit status of the 'tailscale down' call (0 on success, 124 on
# timeout, nonzero on other CLI errors). Does not itself wait for the
# backend to settle -- use ts_wait_for after calling this.
ts_down() {
    _ts_ctl_run_bounded "${TS_CTL_BIN}" down
    return $?
}

# ts_state — print the current BackendState (Running / Stopped /
# NeedsLogin / Starting / etc.) to stdout with no surrounding
# whitespace/quotes, or "Unknown" if it could not be determined (CLI
# missing, call failed/timed out, or output unparsable). Never exits
# non-zero on its own; always prints exactly one line.
ts_state() {
    local json state
    if ! command -v "${TS_CTL_BIN}" >/dev/null 2>&1 && [ ! -x "${TS_CTL_BIN}" ]; then
        echo "Unknown"
        return 0
    fi
    if ! json="$(_ts_ctl_run_bounded "${TS_CTL_BIN}" status --json 2>/dev/null)"; then
        echo "Unknown"
        return 0
    fi
    state="$(printf '%s\n' "${json}" | /usr/bin/awk -F'"' '/"BackendState"/ {print $4; exit}')"
    if [ -z "${state}" ]; then
        echo "Unknown"
        return 0
    fi
    echo "${state}"
    return 0
}

# ts_wait_for <state> <timeout_seconds> — poll ts_state every 0.5s until it
# equals <state> or <timeout_seconds> have elapsed.
#
# Returns: 0 as soon as ts_state == <state> (prints nothing extra on
# success -- ts_state is not echoed by this function). Returns 1 if
# <timeout_seconds> elapses without a match (prints nothing on stdout;
# purely a timeout signal via exit code, per the caller contract).
#
# Arguments:
#   $1  state            required state string to wait for (e.g. "Running")
#   $2  timeout_seconds   required, must be a non-negative integer
#
# If either argument is missing or timeout_seconds is not a non-negative
# integer, returns 2 (usage error) without polling.
ts_wait_for() {
    local want="${1:-}" timeout_s="${2:-}"
    if [ -z "${want}" ] || [ -z "${timeout_s}" ]; then
        return 2
    fi
    case "${timeout_s}" in
        ''|*[!0-9]*) return 2 ;;
    esac

    local elapsed_x10=0 timeout_x10=$((timeout_s * 10))
    while [ "${elapsed_x10}" -le "${timeout_x10}" ]; do
        if [ "$(ts_state)" = "${want}" ]; then
            return 0
        fi
        sleep 0.5
        elapsed_x10=$((elapsed_x10 + 5))
    done

    [ "$(ts_state)" = "${want}" ] && return 0
    return 1
}

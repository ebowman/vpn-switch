#!/bin/bash
# nord-detect.sh — sourceable helper to distinguish NordVPN's two connection
# modes: the native IKEv2 profile (ipsec0, supported alongside Tailscale) and
# the NordVPN app's own tunnel (a utun in 10.5.0.0/16, UNSUPPORTED alongside
# Tailscale because its DNS resolver 100.64.0.2 collides with the tailnet's
# 100.64/10 range and black-holes DNS).
#
# Usage:
#   . lib/nord-detect.sh
#   nord_mode                  # prints one of: ikev2 | app | app+ikev2 | absent
#
# Detection rule:
#   ikev2 : an 'ipsec*' interface has an inet address, OR scutil --dns lists
#           resolver 103.86.96.100 or 103.86.99.100
#   app   : a utun interface has an inet address in 10.5.0.0/16, OR
#           scutil --dns lists resolver 100.64.0.2
#   Both may be true at once; nord_mode reports "app+ikev2" in that case,
#   since the app's presence (the unsupported state) is what matters.
#   Neither -> "absent"
#
# For ikev2/app (not app+ikev2/absent), nord_mode appends the interface name
# in parentheses, e.g. "ikev2(ipsec0)" or "app(utun11)". app+ikev2 and absent
# print bare (no interface can unambiguously represent "both" or "none").
#
# This file has NO side effects when sourced: it only defines functions.
# It performs no mutation and issues no external calls at source time
# (matches lib/tailscale-ctl.sh's contract). Bash 3.2 compatible: no
# 'declare -A', no '${var,,}'.
#
# Testing hook: to unit-test nord_mode without touching real network state,
# override the two data sources it reads by setting these env vars before
# calling nord_mode:
#   NORD_DETECT_IFCONFIG_OVERRIDE   canned `ifconfig` output (multi-line text)
#   NORD_DETECT_SCUTIL_DNS_OVERRIDE canned `scutil --dns` output (multi-line text)
# When either is set (even to an empty string), nord_mode reads that text
# instead of invoking the real command. Not used in normal operation.

set -u

# Scan ifconfig output for an ipsec* block with an inet address. Prints the
# interface name (e.g. "ipsec0") on match, nothing otherwise.
_nord_detect_ikev2_iface_from_ifconfig() {
    local ifconfig_text="$1"
    printf '%s\n' "${ifconfig_text}" | awk '
        /^ipsec[0-9]+:/ { iface = $1; sub(/:$/, "", iface); has_inet = 0; next }
        /^[a-zA-Z]/ { iface = "" }
        iface != "" && /inet /  { has_inet = 1; print iface; exit }
    '
}

# Scan ifconfig output for a utun* block with an inet address in 10.5.0.0/16.
# Prints the interface name (e.g. "utun11") on match, nothing otherwise.
_nord_detect_app_iface_from_ifconfig() {
    local ifconfig_text="$1"
    printf '%s\n' "${ifconfig_text}" | awk '
        /^utun[0-9]+:/ { iface = $1; sub(/:$/, "", iface); next }
        /^[a-zA-Z]/ { iface = "" }
        iface != "" && /inet 10\.5\./ { print iface; exit }
    '
}

# True (0) if scutil --dns output lists resolver 103.86.96.100 or 103.86.99.100.
_nord_detect_scutil_has_ikev2_resolver() {
    local scutil_text="$1"
    printf '%s\n' "${scutil_text}" | grep -q -E '103\.86\.(96|99)\.100'
}

# True (0) if scutil --dns output lists resolver 100.64.0.2.
_nord_detect_scutil_has_app_resolver() {
    local scutil_text="$1"
    printf '%s\n' "${scutil_text}" | grep -q -E '100\.64\.0\.2\b'
}

# nord_mode — print one of: ikev2 | app | app+ikev2 | absent (with interface
# name in parentheses for the ikev2/app single-mode cases). Never aborts the
# caller; always prints exactly one line and returns 0.
nord_mode() {
    local ifconfig_text scutil_text
    local ikev2_iface app_iface have_ikev2 have_app

    if [ -n "${NORD_DETECT_IFCONFIG_OVERRIDE+x}" ]; then
        ifconfig_text="${NORD_DETECT_IFCONFIG_OVERRIDE}"
    else
        ifconfig_text="$(ifconfig 2>/dev/null)"
    fi

    if [ -n "${NORD_DETECT_SCUTIL_DNS_OVERRIDE+x}" ]; then
        scutil_text="${NORD_DETECT_SCUTIL_DNS_OVERRIDE}"
    else
        scutil_text="$(scutil --dns 2>/dev/null)"
    fi

    have_ikev2=0
    have_app=0

    ikev2_iface="$(_nord_detect_ikev2_iface_from_ifconfig "${ifconfig_text}")"
    if [ -n "${ikev2_iface}" ]; then
        have_ikev2=1
    elif _nord_detect_scutil_has_ikev2_resolver "${scutil_text}"; then
        have_ikev2=1
    fi

    app_iface="$(_nord_detect_app_iface_from_ifconfig "${ifconfig_text}")"
    if [ -n "${app_iface}" ]; then
        have_app=1
    elif _nord_detect_scutil_has_app_resolver "${scutil_text}"; then
        have_app=1
    fi

    if [ "${have_app}" -eq 1 ] && [ "${have_ikev2}" -eq 1 ]; then
        echo "app+ikev2"
    elif [ "${have_app}" -eq 1 ]; then
        if [ -n "${app_iface}" ]; then
            echo "app(${app_iface})"
        else
            echo "app"
        fi
    elif [ "${have_ikev2}" -eq 1 ]; then
        if [ -n "${ikev2_iface}" ]; then
            echo "ikev2(${ikev2_iface})"
        else
            echo "ikev2"
        fi
    else
        echo "absent"
    fi
}

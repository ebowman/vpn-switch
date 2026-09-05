#!/bin/bash
# Poll DNS/VPN state every 2s and log to a file, so a VPN transition can be
# captured without needing interactive round-trips while the network is down.
#
# Usage:  bash bin/dns-watch.sh [label] [seconds]
#   label   - name for the log file (default: watch)
#   seconds - how long to run (default: 120)
#
# Start this BEFORE flipping a VPN, let it run through the transition, then
# read snapshots/<label>.log. Read-only; no sudo, no config changes.
# snapshots/ is gitignored; its contents are local-only and never committed.
set -u

TS_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
[ -x "$TS_BIN" ] || TS_BIN="tailscale"

case "${BASH_SOURCE[0]}" in
  */*) SCRIPT_PARENT="${BASH_SOURCE[0]%/*}" ;;
  *)   SCRIPT_PARENT="." ;;
esac
if ! REPO_ROOT="$(cd "$SCRIPT_PARENT/.." 2>/dev/null && pwd)"; then
    echo "Warning: could not resolve repo root; logging to current directory" >&2
    REPO_ROOT="."
fi

# Load the shared NordVPN mode detector (ikev2 vs app vs app+ikev2 vs
# absent). Degrade to a bare "unknown" reading rather than aborting if it is
# missing (matches lib/tailscale-ctl.sh's no-side-effects-on-source
# contract: sourcing it here only defines functions).
NORD_DETECT_LIB="$REPO_ROOT/lib/nord-detect.sh"
if [ -f "$NORD_DETECT_LIB" ]; then
    # shellcheck source=lib/nord-detect.sh
    . "$NORD_DETECT_LIB"
    NORD_DETECT_AVAILABLE=1
else
    NORD_DETECT_AVAILABLE=0
fi

LABEL="${1:-watch}"
DURATION="${2:-120}"
OUTDIR="$REPO_ROOT/snapshots"
OUTFILE="$OUTDIR/$LABEL.log"

mkdir -p "$OUTDIR" 2>/dev/null || { echo "Warning: cannot create $OUTDIR" >&2; OUTFILE="/dev/stdout"; }

# Refuse to overwrite an existing log. Two earlier captures cited as evidence
# were silently destroyed by re-running with the same label; the header write
# below truncates. Set DNS_WATCH_OVERWRITE=1 to allow it deliberately.
if [ -e "$OUTFILE" ] && [ "${DNS_WATCH_OVERWRITE:-0}" != "1" ]; then
    echo "Error: $OUTFILE already exists — pick a new label, or set DNS_WATCH_OVERWRITE=1 to replace it" >&2
    exit 1
fi

# One line of state. Every probe is bounded so a dead network cannot stall us.
sample() {
    local t nord ts_state claimed dns_gen dns_streamy ping_streamy

    t="$(date '+%H:%M:%S' 2>/dev/null || echo '??:??:??')"

    # Nord's interface index drifts between sessions (utun11 has appeared at
    # index 30, 37, 40), so detect by tunnel addressing/resolver instead of a
    # hard-coded name (a hard-coded utun11 produced a false "down" reading
    # and cost us a measurement run). The two NordVPN connection modes are
    # distinguished: 'ikev2' is the native ipsec0-based profile (supported
    # alongside Tailscale); 'app' is the NordVPN app's own tunnel
    # (10.5.0.0/16 / resolver 100.64.0.2) -- the unsupported state that
    # collides with Tailscale's 100.64/10. See lib/nord-detect.sh.
    if [ "$NORD_DETECT_AVAILABLE" -eq 1 ]; then
        nord="$(nord_mode)"
    else
        nord="unknown"
    fi
    case "$nord" in
        absent) nord="down" ;;
    esac

    ts_state="$(timeout 5 "$TS_BIN" status 2>&1 | head -1)"
    case "$ts_state" in
        *"is stopped"*)  ts_state="stopped" ;;
        *"Logged out"*|*"Logged Out"*) ts_state="LOGGED-OUT" ;;
        100.*)           ts_state="up" ;;
        "")              ts_state="(no reply)" ;;
        *)               ts_state="$(echo "$ts_state" | cut -c1-28)" ;;
    esac

    if netstat -rn -f inet 2>/dev/null | grep -q '100\.64/10'; then claimed="yes"; else claimed="no"; fi

    dns_gen="$(timeout 5 dscacheutil -q host -a name apple.com 2>/dev/null | awk '/ip_address/{print $2; exit}')"
    [ -n "$dns_gen" ] || dns_gen="FAIL"

    dns_streamy="$(timeout 5 dscacheutil -q host -a name streamy 2>/dev/null | awk '/ip_address/{print $2; exit}')"
    [ -n "$dns_streamy" ] || dns_streamy="FAIL"

    if timeout 3 ping -c1 -W1000 100.64.10.4 >/dev/null 2>&1; then ping_streamy="ok"; else ping_streamy="FAIL"; fi

    # Reaching the LAN address bypasses both the tailnet and any resolver, so
    # it separates "DNS is broken" from "the network path is gone".
    local ping_lan web
    if timeout 3 ping -c1 -W1000 192.0.2.4 >/dev/null 2>&1; then ping_lan="ok"; else ping_lan="FAIL"; fi

    # DNS resolving and ICMP working do NOT mean the machine is usable — with
    # Nord up the browser fails while both of those still report green. Only a
    # completed TCP/TLS fetch proves real connectivity, so it decides the
    # verdict; never call a state "working" without this column passing.
    web="$(timeout 8 curl -s -o /dev/null -w '%{http_code}' --max-time 7 https://example.com 2>/dev/null)"
    case "$web" in
        2*|3*) web="ok($web)" ;;
        "")    web="FAIL" ;;
        *)     web="FAIL($web)" ;;
    esac

    printf '%s  nord=%-14s ts=%-11s claim=%-3s inet-dns=%-15s streamy-dns=%-15s ts-ping=%-4s lan-ping=%-4s WEB=%s\n' \
        "$t" "$nord" "$ts_state" "$claimed" "$dns_gen" "$dns_streamy" "$ping_streamy" "$ping_lan" "$web"
}

{
    echo "=== dns-watch: $LABEL ==="
    echo "started: $(date 2>/dev/null || echo unknown)  duration: ${DURATION}s"
    echo "columns: nord=NordVPN mode (ikev2(ipsec0)=native profile, app(utunN)=app tunnel"
    echo "         [UNSUPPORTED w/ tailscale], app+ikev2=both, down=neither)"
    echo "         ts=tailscale state  claim=100.64/10 claimed"
    echo "         inet-dns/streamy-dns=resolved addr or FAIL  ts-ping/lan-ping=ICMP"
    echo "         WEB=real HTTPS fetch — the ONLY column that proves usability."
    echo "         DNS+ICMP can all read green while the browser is dead; trust WEB."
    echo ""
} | tee "$OUTFILE"

elapsed=0
while [ "$elapsed" -lt "$DURATION" ]; do
    sample | tee -a "$OUTFILE"
    sleep 2
    elapsed=$((elapsed + 2))
done

echo "" | tee -a "$OUTFILE"
echo "=== done: $OUTFILE ===" | tee -a "$OUTFILE"
exit 0

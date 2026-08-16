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

LABEL="${1:-watch}"
DURATION="${2:-120}"
OUTDIR="$REPO_ROOT/snapshots"
OUTFILE="$OUTDIR/$LABEL.log"

mkdir -p "$OUTDIR" 2>/dev/null || { echo "Warning: cannot create $OUTDIR" >&2; OUTFILE="/dev/stdout"; }

# One line of state. Every probe is bounded so a dead network cannot stall us.
sample() {
    local t nord ts_state claimed route_if dns_gen dns_streamy ping_streamy

    t="$(date '+%H:%M:%S' 2>/dev/null || echo '??:??:??')"

    if ifconfig utun11 2>/dev/null | grep -q 'inet '; then nord="up"; else nord="down"; fi

    ts_state="$(timeout 5 "$TS_BIN" status 2>&1 | head -1)"
    case "$ts_state" in
        *"is stopped"*)  ts_state="stopped" ;;
        *"Logged out"*|*"Logged Out"*) ts_state="LOGGED-OUT" ;;
        100.*)           ts_state="up" ;;
        "")              ts_state="(no reply)" ;;
        *)               ts_state="$(echo "$ts_state" | cut -c1-28)" ;;
    esac

    if netstat -rn -f inet 2>/dev/null | grep -q '100\.64/10'; then claimed="yes"; else claimed="no"; fi

    route_if="$(route -n get 100.64.0.2 2>/dev/null | awk '/interface:/{print $2}')"
    [ -n "$route_if" ] || route_if="none"

    dns_gen="$(timeout 5 dscacheutil -q host -a name apple.com 2>/dev/null | awk '/ip_address/{print $2; exit}')"
    [ -n "$dns_gen" ] || dns_gen="FAIL"

    dns_streamy="$(timeout 5 dscacheutil -q host -a name streamy 2>/dev/null | awk '/ip_address/{print $2; exit}')"
    [ -n "$dns_streamy" ] || dns_streamy="FAIL"

    if timeout 3 ping -c1 -W1000 100.64.10.4 >/dev/null 2>&1; then ping_streamy="ok"; else ping_streamy="FAIL"; fi

    printf '%s  nord=%-4s ts=%-12s claim=%-3s rt=%-7s inet-dns=%-15s streamy-dns=%-15s streamy-ping=%s\n' \
        "$t" "$nord" "$ts_state" "$claimed" "$route_if" "$dns_gen" "$dns_streamy" "$ping_streamy"
}

{
    echo "=== dns-watch: $LABEL ==="
    echo "started: $(date 2>/dev/null || echo unknown)  duration: ${DURATION}s"
    echo "columns: nord=NordVPN iface  ts=tailscale state  claim=100.64/10 claimed"
    echo "         rt=where 100.64.0.2 routes  inet-dns/streamy-dns=resolved addr or FAIL"
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

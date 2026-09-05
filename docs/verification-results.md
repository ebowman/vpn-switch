# Verification matrix — IKEv2 era (beads dns-config-c15.6, c15.2, qsk.8)

Date: 2026-08-16. Home LAN (en0 192.0.2.64). Tailscale 1.102.2 standalone.
NordVPN via the IKEv2 profile (`de1545.nordvpn.com`). NordVPN **app** tunnel
never connected during any row below. Judged against ADR-002: with
Tailscale off, tailnet names are *expected* to fail (only `.local` works) —
that row passes if web works and the failure is exactly that.

Columns: `dns-verify` = `bin/dns-verify.sh` summary; `WEB` = HTTPS fetch
(the decisive usability column); names = bare `streamy` / `mac-mini`.

Evidence files under `snapshots/` are local captures kept by the maintainer, not committed to the repository (they contain tailnet and LAN details).

| Row | nord (IKEv2) | tailscale | dns-verify | WEB | bare names | Verdict | Evidence |
|---|---|---|---|---|---|---|---|
| 1 | on | on | 6 passed, 0 failed, 0 skipped | ok(200) | 100.64.10.4 / 100.64.10.65 | **PASS** — the normal state | `snapshots/ts-on-nordikev2-on.txt`; `snapshots/soak-both-up-30min.log`; qsk.10 |
| 2 | on | off | 4 FAIL (names/services), 2 SKIP (staleness) — as designed | ok(200) via Nord | no answer (expected) | **PASS per ADR-002** — internet via Nord, tailnet unavailable | `snapshots/ts-off-nordikev2-on.txt`; `snapshots/qsk8-ts-off.log` |
| 3 | off | on | 6 passed (measured 2026-08-15/16 before IKEv2 was connected; state identical: no Nord tunnel) | ok(200) | 100.64.10.4 / 100.64.10.65 | **PASS** | `snapshots/ts-on-nord-off.txt`; qsk.1 round-trips |
| 4 | off | off | — | — | — | **SUPERSEDED** — see LAN fallback row "L4 (re-measured)" below (2026-08-17, via the app/Shortcuts) | — |
| A1 | on | on → off → on | Stopped in 3 s, Running in 2 s via the **installed app's menu**; WEB ok throughout | ok(200) | restored | **PASS** — transitions through the app | `snapshots/qsk8-ts-off.log`, `snapshots/qsk8-ts-on.log` (qsk.8) |
| A2 | on → off / off → on via app | on | — | — | — | **SUPERSEDED** — see "Transition latency" under LAN fallback below (2026-08-17: measured via `vpn-ctl.sh`/Shortcuts, rows L3/L4) | qsk.8 comment 2026-08-17 |
| E1 | app tunnel present (simulated) | on | collision row FAILs; app shows ⚠︎ App tunnel (unsupported) | — | — | **PASS** — error state detected, no auto-fix | c15.8 override test; qsk.6 review |
| S1 | on | on, 30-min soak @2 s | see soak log | all ok(200) except the deliberate A1 window | — | see `snapshots/soak-both-up-30min.log` (qsk.11) | — |
| — | away (hotspot) rows | | | | | **NOT CAPTURED** — no away network available unattended | — |
| — | sleep / wake | | | | | **NOT TESTED** — cannot be run unattended | — |

## Reading the table

- Rows 1–3 and A1 cover everything a person at home does day to day: both
  on (normal), Tailscale off for a moment, Nord off, and toggling Tailscale
  from the menu bar. All pass, and the one "failure" (row 2's tailnet names)
  is the documented behaviour of not running Tailscale.
- Row 4 and A2 are superseded by the LAN fallback section below, which now
  has measured rows for both (2026-08-17, via the two Shortcuts and
  `vpn-ctl.sh`).
- E1 is the one configuration this whole project exists to prevent (the
  NordVPN app's tunnel alongside Tailscale). It was exercised through the
  detection override rather than by actually connecting the app tunnel,
  because doing so black-holes DNS on the machine and it was unattended.
- Rows 2 and 4 above are superseded by the LAN fallback section below — see
  that section for the current (post-ADR-003) verdicts for those states.

## LAN fallback (bead dns-config-j9y.4)

After ADR-003 (`docs/adr-003-lan-fallback.md`, esp. §2a) the bare names
`streamy` / `mac-mini` are expected to resolve to tailnet IPs
(100.64.10.4 / 100.64.10.65) while Tailscale is up, and to LAN IPs
(192.0.2.4 / 192.0.2.65) while it is down, via dnsmasq on
`127.0.0.1:5354` for `home.arpa`, `/etc/resolver/home.arpa`, and a
`home.arpa` search suffix (added to the Wi-Fi service and to the Nord
IKEv2 profile's `DNS.SearchDomains`). This section supersedes rows 2 and 4
of the IKEv2-era table above — row 2's "no answer (expected)" is no longer
the expected behaviour now that the LAN fallback is in place.

| Row | nord (IKEv2) | tailscale | Global SearchDomains (State:/Network/Global/DNS) | bare streamy → | bare mac-mini → | dns-verify | WEB | Verdict | Measured |
|---|---|---|---|---|---|---|---|---|---|
| L1 | on | on | `tailXXXX.ts.net home.arpa` (PrimaryInterface ipsec0) | 100.64.10.4 | 100.64.10.65 | 6 passed, 0 failed, 0 skipped (staleness "matches live Tailscale IP") | 200 in 0.28 s | **PASS** | 2026-08-17 ~00:35 and again 2026-08-17 (transition run) |
| L2 | on | off | `home.arpa` (PrimaryInterface ipsec0) | 192.0.2.4 (dscacheutil wall clock 0.01 s) | 192.0.2.65 (:22 open via bare name) | 6 passed, 0 failed, 0 skipped (State: tailscale=down nordvpn=ikev2(ipsec0) lan-dns=answering; staleness "matches LAN table") | 200 in 0.31 s via Nord | **PASS** | 2026-08-17 ~00:35 and transition run |
| L3 | off | on | `tailXXXX.ts.net local home.arpa` | 100.64.10.4 (Tailscale's suffix first — tailnet still wins) | 100.64.10.65 | 6/6 (State: tailscale=up nordvpn=absent lan-dns=answering) | ok(200) 0.13 s | **PASS — full row** | 2026-08-17 18:24 (`nord on→off`, ts on, via `vpn-ctl.sh`; egress 203.0.113.26/ISP) |
| L4 | off | off | `local home.arpa` (en0 primary) | 192.0.2.4 (0.02–0.05 s, stable across 10 polls over 20 s; :5000 open via bare name) | 192.0.2.65 (:22 open) | 6 passed, 0 failed, 0 skipped (State: tailscale=down nordvpn=absent lan-dns=answering) | not recorded | **PASS** — first time a bare name has ever resolved with Tailscale off on this machine | 2026-08-17 ~00:20 |
| L4 (re-measured) | off | off | `local home.arpa` → resolver#1 192.0.2.1 (router) | **FAIL with `local` present**: no answer, 5.05 s per lookup (mDNS from Synology answers only after ~5.3 s, too late); **PASS after removing `local`** (`sudo networksetup -setsearchdomains Wi-Fi home.arpa`): 192.0.2.4 in 0.04 s | 192.0.2.65 in 0.06 s even with `local` present (fast mDNS — coincidence, not evidence `local` is safe); 0.04 s after removal | 3 passed/2 failed/1 skipped with `local` present; 6/6 after removal | ok(200) 0.05 s | **FAIL → PASS** (root cause: `local` as a search suffix when Wi-Fi is primary; see ADR-003 §1 correction) | 2026-08-17 18:24; `snapshots/ts-off-nord-off.txt` captured after removal |
| L5 | any | any | away / hotspot | — | — | — | — | **NOT TESTED** (no away network available unattended); ADR-003 §2a: away+TS-on expected tailnet IPs (dnsmasq serves tailnet IPs while TS is up, so correct regardless of suffix order); away+TS-off has no correct answer by design | — |

The original L4 row (and the names-only L3 measurement of 2026-08-17 ~00:20) were taken during the ~15 min window in which the profile reinstall had dropped the IKEv2 tunnel. On 2026-08-17 (afternoon), once the two Shortcuts existed, both states were re-entered via `vpn-ctl.sh` and re-measured — L3 above is now a full row, and L4's re-measurement follows.

### Transition latency

Measured 2026-08-17, Nord IKEv2 on throughout:

- `bin/vpn-ctl.sh tailscale off`: rc 0, returned at +4 s (its own ts wait +
  `lan_dns_sync`); the first probe at +4 s already returned
  streamy=192.0.2.4, mac-mini=192.0.2.65. Global SearchDomains
  had become `[home.arpa]`.
- `bin/vpn-ctl.sh tailscale on`: rc 0 at +1 s; first probe at +1 s returned
  the tailnet IPs; SearchDomains `[tailXXXX.ts.net, home.arpa]`.
- Earlier the same night (bead dns-config-j9y.3, flips done by hand in the
  GUI, probe taken inside the window) a one-off ~10 s stale answer was
  observed after a flip (mDNSResponder cache); `dscacheutil -flushcache`
  did not shorten it; `sudo killall -HUP mDNSResponder` would, but no
  script runs it. With vpn-ctl sequencing (wait for Tailscale state, then
  re-render dnsmasq's hosts file + SIGHUP) no lag was measurable. Finding:
  no cache flush is needed in vpn-ctl; the ~10 s is the worst case after an
  *external* flip (Tailscale menu / GUI) until the app re-syncs — tracked
  as bead dns-config-qsk.12.
- Nord on/off transitions: measured 2026-08-17 18:24 via `bin/vpn-ctl.sh`
  (the app's exact code path), using the two Shortcuts ('NordVPN On' /
  'NordVPN Off', runbook §3(c)), home LAN:
  - `nord on → off` (ts on): rc 0 at +0 s (shortcut returns immediately;
    `ipsec0` gone at +3 s). Resulting state (nord off, ts on) is row L3
    above.
  - `ts on → off` (nord off): rc 0 at +5 s. Resulting state (off, off) is
    the L4 re-measurement row above.
  - `ts off → on` (nord off): rc 0 at +3 s; first probe at +3 s already
    returned tailnet IPs; SearchDomains `tailXXXX.ts.net home.arpa`.
  - `nord off → on` (ts on): rc 0 at +3 s; `ipsec0` 10.6.0.41 present;
    SearchDomains `tailXXXX.ts.net home.arpa`; bare names → tailnet IPs;
    WEB 200 in 0.21 s; egress 187.40.54.188 (Nord); dns-verify 6/6.

### Not covered / limits

- Away rows (L5): no away/hotspot network available unattended.
- Sleep / wake: not exercised in this pass.
- NordVPN app tunnel present alongside Tailscale — the recovery test
  (connecting Nord's own app tunnel by hand and confirming detection/fix):
  not exercised in this pass, deliberately (would black-hole DNS
  unattended; requires the human present).
- LAN addresses in `config/lan-hosts.conf` can go stale under DHCP
  (ADR-003 §4) — not something this verification pass can detect.

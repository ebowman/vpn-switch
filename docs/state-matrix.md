# State matrix — what resolver #1 is, and what resolves, per VPN state

Extracted from committed `snapshots/*.txt` (captured by `bin/dns-snapshot.sh`
on this Mac, home LAN). Each cell is the literal observed value.

| State | Snapshot | Captured | resolver #1 (`scutil --dns`) | nord-mode | bare `streamy` | bare `mac-mini` | `streamy.local` | Web |
|---|---|---|---|---|---|---|---|---|
| Tailscale on, Nord off | `ts-on-nord-off.txt` | 2026-08-15 23:55 | `100.100.100.100` (MagicDNS) | absent | 100.64.10.4 | 100.64.10.65 | 192.0.2.4 | ok |
| Tailscale on, **Nord IKEv2** on | `ts-on-nordikev2-on.txt` | 2026-08-16 12:5x | `100.100.100.100` (MagicDNS; Nord's `103.86.96.100` is #2) | ikev2(ipsec0) | 100.64.10.4 | 100.64.10.65 | 192.0.2.4 | ok |
| Tailscale off, **Nord IKEv2** on | `ts-off-nordikev2-on.txt` | 2026-08-16 13:0x | `103.86.96.100` (Nord, public) | ikev2(ipsec0) | no answer (expected) | no answer (expected) | 192.0.2.4 | ok |
| Tailscale off, **Nord APP** on | `ts-off-nord-on.txt` | 2026-08-16 00:39 | `100.64.0.2` (Nord app — inside CGNAT space) | app (pre-detection capture) | no answer (expected) | no answer (expected) | 192.0.2.4 | ok |
| Tailscale on, **Nord APP** on | *(not captured as a snapshot — see `snapshots/ts-then-nord-2.log`, `openvpn-udp-nord.log`, `custom-dns-nord.log`)* | 2026-08-16 09:26–10:25 | `100.64.0.2` first; MagicDNS never consulted | app | FAIL | FAIL | ok | **FAIL** (total DNS loss; browser dead) — the unsupported state |
| Tailscale off, Nord off | NOT CAPTURED (no dns-snapshot; Nord IKEv2 off needs a human System Settings toggle) | — | `192.0.2.1` (router) | absent | no answer (pre-ADR-003) → 192.0.2.4 since 2026-08-17 (L4) | no answer (pre-ADR-003) → 192.0.2.65 since 2026-08-17 (L4) | 192.0.2.4 | ok | 
| Away (hotspot), any | — | NOT CAPTURED | — | — | — | — | — | — |

The last "off/off" row is the trivial baseline (nothing but the router
resolver). Its resolver-#1 and bare-name values come from the L4 row of
`docs/verification-results.md` (2026-08-17 ~00:20; dns-verify 6/6, bare
names → LAN IPs) and from repeated observation during setup, not from a
`bin/dns-snapshot.sh` capture; a snapshot can be taken with
`bash bin/vpn-ctl.sh tailscale off && bash bin/dns-snapshot.sh ts-off-nord-off && bash bin/vpn-ctl.sh tailscale on`
once Nord can be turned off from the CLI.

## What this shows

1. **Bare names work whenever Tailscale is up and the Nord *app* tunnel is
   not** — MagicDNS is resolver #1 in both such rows, regardless of whether
   Nord IKEv2 is connected. That is the epic's goal, met.
2. **The only failing configuration is Tailscale + the Nord app tunnel**,
   and the reason is visible in one column: its resolver #1 is
   `100.64.0.2`, an address inside the `100.64.0.0/10` range Tailscale
   claims, so every DNS query is routed into the tailnet and dropped.
3. **Nord IKEv2's resolver is `103.86.96.100`** — Nord's public DNS, outside
   CGNAT space. That single difference between the app and the protocol is
   the whole reason IKEv2 coexists and the app does not.
4. With Tailscale off, tailnet names are unavailable by construction and
   `.local` names still work via mDNS — as ADR-001/ADR-002 both state.
   Not a regression; the switcher's job is to make turning Tailscale back
   on one click.

   **Note, dated 2026-08-17:** since ADR-003 (`docs/adr-003-lan-fallback.md`),
   the "Tailscale off, Nord IKEv2 on" row's bare-name cells above ("no
   answer (expected)") no longer describe current behaviour, and the
   "Tailscale off, Nord off" row above has been updated in place to show
   both the pre-ADR-003 and current values — both states now answer LAN IPs
   via the dnsmasq/`home.arpa` fallback; see the "LAN fallback" section of
   `docs/verification-results.md` for the current measurements. The
   snapshots this table is built from predate ADR-003 and are left as
   literal, unmodified captures of the state at the time they were taken.

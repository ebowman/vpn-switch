# vpn-switch

NordVPN and Tailscale coexist on one Mac without breaking DNS.

![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)

## 1. The problem

The NordVPN app's NordLynx tunnel installs a DNS resolver at `100.64.0.2`.
That address sits inside `100.64.0.0/10`, the CGNAT range Tailscale claims
and routes for its own tailnet addressing. When both are up, Tailscale's
route captures every query addressed to Nord's resolver and nothing answers
it — DNS is black-holed, and with it general connectivity: the Mac appears
to have no network. Neither product is misconfigured; two products simply
use the same unregistered range.

## 2. The fix

Run NordVPN over a native IKEv2 configuration profile instead of the app.
Nord's IKEv2 servers push a documented resolver (`103.86.96.100` /
`103.86.99.100`) and a `10.6.x` tunnel address, both outside
`100.64.0.0/10`. There is nothing for Tailscale's route to capture, and the
two coexist. **VPN Switch**, a menu bar app, gives
independent on/off control of each VPN. A local dnsmasq resolver for the
`home.arpa` suffix makes bare LAN hostnames (`streamy`, not
`streamy.tail...ts.net`) resolve correctly whether Tailscale is on or off.
Full reasoning: [ADR-002](docs/adr-002-nordvpn-ikev2.md) (the IKEv2 switch)
and [ADR-003](docs/adr-003-lan-fallback.md) (the LAN fallback).

## 3. Quick start

1. Install Tailscale — the **standalone** build from tailscale.com, not the
   App Store version (the CLI is required) — and log in.
2. Get NordVPN IKEv2 service credentials (Nord Account → Manual setup) and
   an IKEv2 server hostname. Write them to
   `~/Library/Application Support/vpn-switch/nord-ikev2.env` (mode 600) as
   `NORD_IKEV2_SERVER`, `NORD_IKEV2_USER`, `NORD_IKEV2_PASS` lines, then run:

   ```bash
   NORD_IKEV2_ENVFILE="$HOME/Library/Application Support/vpn-switch/nord-ikev2.env" \
     bash bin/nord-ikev2-profile.sh
   ```

3. Double-click the generated `.mobileconfig`, install it under System
   Settings → Profiles, then System Settings → VPN → NordVPN IKEv2 → toggle
   on. Never connect the NordVPN app's own tunnel again.
4. In Shortcuts.app, create two shortcuts using the Set VPN action targeting
   NordVPN IKEv2: one set to Connect, named exactly `NordVPN On`; one set to
   Disconnect, named exactly `NordVPN Off`.
5. ```bash
   bash bin/install-vpn-switch.sh
   ```
   Builds and ad-hoc signs VPN Switch, installs it to
   `/Applications/VPN Switch.app`, and registers a login item.
6. ```bash
   bash bin/lan-dns-install.sh
   ```
   Then run the two `sudo` commands it prints. These are the only root steps
   in the project, and both are reversible.
7. ```bash
   bash bin/dns-verify.sh
   ```
   Expected: `Summary: 6 passed, 0 failed, 0 skipped`.

Full step-by-step detail, troubleshooting, and daily-use notes:
[docs/runbook.md](docs/runbook.md).

## 4. What is in the repo

| Path | Contents |
|---|---|
| `bin/` | Entry-point scripts: verify, watch, snapshot, install/uninstall, profile generator. |
| `lib/` | Shared shell logic sourced by `bin/` (Nord and Tailscale control/detection, LAN DNS). |
| `app/` | VPN Switch, the SwiftUI menu bar app (`app/VPNSwitch/`). |
| `config/` | `lan-hosts.conf` (LAN/tailnet address table) and the NordVPN IKEv2 root CA. |
| `docs/` | Runbook, findings, ADRs, verification results, and background research. |
| `snapshots/` | Captured evidence logs from `dns-watch.sh` / `dns-snapshot.sh` runs. |

## 5. Status and limits

- Measured on macOS 26 (Darwin 25), Tailscale 1.102 standalone, one NordVPN
  IKEv2 server. Verified on a single Mac; ADR-002 argues why the collision
  is general.
- With both VPNs up: `dns-verify` 6/6, a 35-minute soak (900 samples at 2 s
  intervals, zero web failures), and IKEv2 throughput of 216/200/194 Mbit/s.
- Never measured: away/hotspot networks, sleep/wake cycles, and recovery
  after the NordVPN app's own tunnel is connected by mistake.
- No kill switch — a dropped IKEv2 tunnel fails open, unlike the app.
- No Threat Protection — the app's DNS-based blocking does not apply to a
  bare IKEv2 tunnel.
- One pinned NordVPN server. Rotating servers means regenerating the
  profile by hand.
- The generated `.mobileconfig` contains the NordVPN service password in
  plaintext, mode 600, stored outside this repo. Treat that file as a
  credential.
- After a Tailscale change made outside VPN Switch (for example from the
  Tailscale menu bar item), a bare LAN name can serve a stale answer for up
  to ~10 s until VPN Switch resyncs.

## 6. Read more

- [docs/runbook.md](docs/runbook.md) — full setup, daily use, verification,
  and troubleshooting.
- [docs/findings.md](docs/findings.md) — the diagnostic narrative: what was
  observed, what was tried, what worked.
- [docs/adr-002-nordvpn-ikev2.md](docs/adr-002-nordvpn-ikev2.md) — the
  decision to run NordVPN over IKEv2.
- [docs/adr-003-lan-fallback.md](docs/adr-003-lan-fallback.md) — the
  decision behind the LAN DNS fallback.
- [docs/verification-results.md](docs/verification-results.md) — the full
  measurement matrix.
- [docs/research/](docs/research/) — background on the CGNAT collision and
  how other tools hit the same class of problem.

## 7. License

MIT. See [LICENSE](LICENSE).

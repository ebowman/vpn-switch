# ADR-003: LAN fallback for bare hostnames when Tailscale is off

- **Status:** Accepted (operator chose option C, 2026-08-16)
- **Date:** 2026-08-16
- **Relates to:** ADR-002 (scenario C: "Tailscale off ⇒ `.local` only") — this ADR closes that gap.

## 1. Context

After ADR-002, bare `streamy` / `mac-mini` resolve correctly whenever
Tailscale is up (MagicDNS answers via the `tailXXXX.ts.net` search suffix
Tailscale installs while it runs). With Tailscale off they return **no
answer** — only `streamy.local` (mDNS) works. Now that turning Tailscale off
is a one-click, deliberate action (VPN Switch), that state is routine and
the names should keep working at home. The mechanism should be *general*
(any LAN host, not just these two).

Why the bare name fails with Tailscale off, precisely: macOS turns a
single-label name into something resolvable only by appending a **search
domain**. Tailscale supplies one; nothing else does.

Measured before deciding (`docs/hostnames/search-domain-results.md`):

- Adding `local` as a search domain does **nothing**. With Tailscale off and
  `local` the only search entry, bare `streamy` returns no answer in ~10 ms
  — not the LAN address, and not the ~10 s an attempted mDNS query costs
  when a host is absent. `dns-sd -E/-F` show `local` is the Bonjour
  registration/browsing zone; macOS excludes it from search-path synthesis.
- A *unicast* search domain **is** applied to bare names — that is exactly
  how `tailXXXX.ts.net` works today (bare `phone`, no mDNS,
  resolves in 30 ms with Tailscale up).
- Search order with Tailscale up: Tailscale's suffix first, then the Wi-Fi
  service's. Tailnet names keep winning while Tailscale runs.

## 2. Decision

**Run a tiny local unicast resolver for a private suffix, and make that
suffix a search domain.**

- Suffix: **`home.arpa`** — RFC 8375's special-use domain for home networks.
  It is IANA-rooted, so it avoids the macOS 26 behaviour (recorded on
  `dns-config-c15.3`) of silently ignoring `/etc/resolver` for non-IANA TLDs
  such as `.home`, `.lan`, `.internal`.
- Resolver: **dnsmasq** (Homebrew), running as the **user** via a
  LaunchAgent, bound to `127.0.0.1` on a high port (5354), authoritative for
  `home.arpa` (`local=/home.arpa/`), no upstream (`no-resolv`), answering
  from a generated config derived from one hosts-style file in this repo:
  `config/lan-hosts.conf` (`streamy 192.0.2.4`, `mac-mini 192.0.2.65`).
- Routing: `/etc/resolver/home.arpa` containing `nameserver 127.0.0.1` and
  `port 5354` — a domain-scoped resolver, which macOS selects by
  longest-suffix specificity before any `order` value (source-code evidence
  on `dns-config-c15.3`).
- Search domain: `home.arpa` added to the Wi-Fi (and any other active)
  service's search list, *after* whatever is already there.

Root is needed **twice, once, at install** (writing `/etc/resolver/home.arpa`;
`networksetup -setsearchdomains`) and never at runtime. The install script
prints those two commands; it does not run `sudo` (project rule).

Expected behaviour by state:

| State | bare `streamy` → | via |
|---|---|---|
| Tailscale on (home or away) | 100.64.10.4 | `tailXXXX.ts.net` suffix, MagicDNS (unchanged) |
| Tailscale off, at home | 192.0.2.4 | `home.arpa` suffix → dnsmasq |
| Tailscale off, away | 192.0.2.4 (unreachable) | same — a fast connection failure; **no design has a correct answer in this state** |
| both VPNs on | 100.64.10.4 | unchanged from ADR-002 |

Note the correction to an earlier informal claim: away with Tailscale off,
this design answers the LAN IP; it does not return "no answer". Both fail
to connect; this one fails fast.

## 3. Alternatives considered

- **(A) `local` search domain** — REJECTED, measured not to work (above).
- **(B′) static `/etc/hosts` with LAN IPs** — REJECTED. Simplest possible
  (two lines, no daemon) and correct in all four home states — but
  `/etc/hosts` is consulted before every resolver, so away from home with
  Tailscale up it would shadow MagicDNS with an unreachable LAN address and
  break bare names precisely when travelling. Acceptable only for a
  home-only user; the operator did not choose it.
- **(B) dynamic `/etc/hosts`** rewritten on each Tailscale flip — REJECTED.
  Correct everywhere and general via a config file, but requires a root
  write on every toggle (sudoers NOPASSWD for one script, or a root
  LaunchDaemon watching Tailscale). The most machinery for the least gain
  over C, and the only option that puts root on the hot path.
- **NEVPNManager / DNS profile / MagicDNS tricks** — not applicable; the gap
  is with Tailscale *off*.

## 4. Consequences

- One new user-level daemon (dnsmasq via LaunchAgent) to keep alive; the
  app/verify scripts should be able to tell when it is not answering.
- `config/lan-hosts.conf` becomes the single source of LAN addresses; the
  install regenerates dnsmasq's config from it; `dns-verify.sh` reads the
  same file for its Tailscale-off expectations. LAN addresses can still go
  stale (DHCP) — the Synology and mac mini should have DHCP reservations
  or static addresses; verify checks connectivity, not just resolution.
- `dns-verify.sh` becomes state-aware: bare names → tailnet IP when
  Tailscale is up, LAN IP (from the conf) when down; staleness compares
  against the matching table; service checks must pass with Tailscale off
  at home.
- `home.arpa` names are also usable explicitly (`streamy.home.arpa`) in any
  state, including with Tailscale up.
- Uninstall: LaunchAgent unload + brew uninstall dnsmasq + remove
  `/etc/resolver/home.arpa` (sudo) + remove `home.arpa` from search domains
  (admin). Documented.

## 5. Open questions (to be answered by measurement in j9y.3/j9y.4)

- Does macOS honour `/etc/resolver/home.arpa` on this OS version (given
  `.arpa` is also where reverse-lookup zones live)? Expected yes; must be
  measured, not assumed — and with `dscacheutil`, never `dig`.
- Search order once `home.arpa` is on the Wi-Fi list while Tailscale is up:
  expected `tailXXXX.ts.net` first (Tailscale's supplemental list precedes
  the primary service's) — verify; if reversed, bare names would resolve to
  LAN IPs at home with Tailscale up (harmless at home, wrong away).
- Transition latency after `tailscale off`: does a cached tailnet answer for
  `streamy` linger, and for how long? Measure; if material, `vpn-ctl.sh`
  should flush the cache after a toggle.

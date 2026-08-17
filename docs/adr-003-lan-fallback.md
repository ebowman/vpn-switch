# ADR-003: LAN fallback for bare hostnames when Tailscale is off

- **Status:** Accepted (operator chose option C, 2026-08-16); **amended 2026-08-16 23:40** after implementation measurements — see §2a
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

- Adding `local` as a search domain does **nothing** — *while a VPN is
  primary* (that was the state under test here: Tailscale off, Nord IKEv2
  on). With Tailscale off and `local` the only search entry, bare `streamy`
  returns no answer in ~10 ms — not the LAN address, and not the ~10 s an
  attempted mDNS query costs when a host is absent. `dns-sd -E/-F` show
  `local` is the Bonjour registration/browsing zone; macOS excludes it from
  search-path synthesis while a VPN service is primary.
  **Correction (2026-08-17):** when Wi-Fi is primary instead (both VPNs
  off), macOS *does* apply `local` as a search suffix, and it is actively
  harmful: with the effective list `local home.arpa`, bare `streamy` tried
  `streamy.local` first, the Synology's mDNS answered only after ~5.3 s, and
  the lookup gave up (no answer, 5.05 s per lookup) before ever trying
  `home.arpa`. Removing `local` from the Wi-Fi search list fixed it: bare
  `streamy` → 192.0.2.4 in 0.04 s. Decision: `local` must not be in the
  search list, in any state.
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
  service's search list, excluding `local` if present (2026-08-17: `local`
  as a search suffix is harmful when that service is primary — see §1
  correction).

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

## 2a. Amendment (2026-08-16, after applying the root steps)

Applying the design exposed one wrong assumption and produced two
refinements. Both are still "option C" — dnsmasq + `home.arpa` +
`/etc/resolver` — but the *search suffix* has to be attached differently,
and dnsmasq should answer per state.

**What was measured** (bead `dns-config-j9y.3`):

- `/etc/resolver/home.arpa` with `port 5354` **works** on this macOS: the
  system resolver returns 192.0.2.4 for `streamy.home.arpa` (Homebrew's
  caveat about non-53 ports on 127.0.0.1 did not bite).
- With `home.arpa` on Wi-Fi's search list and Tailscale off, bare `streamy`
  still returned **no answer** — and dnsmasq's query log showed **no
  `streamy.home.arpa` query ever arrived**. macOS never expanded the name.
- Why: `State:/Network/Global/DNS` — the search list macOS actually applies
  to unqualified names — held **only** `tailXXXX.ts.net`. The primary
  service was the NordVPN IKEv2 configuration on `ipsec0`, whose
  server-pushed DNS has no search domains; Wi-Fi's list is not consulted
  when Wi-Fi is not primary. Tailscale's suffix gets in regardless because
  it is registered as a NetworkExtension *supplemental match* domain. (This
  retroactively explains why the `local` search domain measured in j9y.1 did
  nothing either.)

**Refinement 1 — attach the suffix to the primary.** Apple's VPN payload
`DNS` dictionary has `SearchDomains` ("used to fully qualify single-label
host names"); the NordVPN IKEv2 profile now carries
`DNS.SearchDomains=[home.arpa]` with `ServerAddresses` = Nord's documented
`103.86.96.100/103.86.99.100` (required key; identical to what the server
pushes) and `DNSProtocol=Cleartext`. Wi-Fi keeps `home.arpa` for the states
where Wi-Fi is primary (Nord off). Routing of the expanded name is
unchanged: `/etc/resolver/home.arpa` (domain-scoped, chosen by specificity).
Fallback if a non-MDM personal-VPN profile ignores its DNS dictionary: a
`com.apple.dnsSettings.managed` profile with `SupplementalMatchDomains` —
which cannot carry a port, so dnsmasq would need 127.0.0.1:53 and therefore
a root LaunchDaemon (a privilege decision for the operator).

**Refinement 2 — dnsmasq answers the right address for the state.** Names
are served from a generated hosts file (`addn-hosts`, re-read on `SIGHUP`)
that `vpn-ctl.sh` re-renders when Tailscale changes: **tailnet IPs while
Tailscale is up, LAN IPs while it is down.** `config/lan-hosts.conf` gains a
tailnet column. Consequence: bare names are correct in every state
*regardless of which suffix macOS tries first* — including away from home
with Tailscale up — with no root at runtime, since dnsmasq is user-level.
This is the dynamism of the `/etc/hosts` idea without touching `/etc/hosts`.

Revised expected behaviour:

| State | bare `streamy` → | suffix from | answer from |
|---|---|---|---|
| Tailscale on, Nord IKEv2 on | 100.64.10.4 | `tailXXXX.ts.net` (Tailscale) or `home.arpa` (Nord profile) — order irrelevant | MagicDNS or dnsmasq (tailnet IP either way) |
| Tailscale on, Nord off | 100.64.10.4 | `tailXXXX.ts.net` or `home.arpa` (Wi-Fi) | same |
| Tailscale off, Nord IKEv2 on | 192.0.2.4 | `home.arpa` (Nord profile) | dnsmasq, LAN IP |
| Tailscale off, Nord off | 192.0.2.4 | `home.arpa` (Wi-Fi; `local` removed) | dnsmasq, LAN IP |
| Away, Tailscale on | 100.64.10.4 | as above | tailnet IP — reachable |
| Away, Tailscale off | 192.0.2.4 (unreachable) | — | no correct answer exists |

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

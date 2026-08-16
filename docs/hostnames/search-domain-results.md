# 'local' search-domain approach — measurements (bead dns-config-j9y.1)

Date: 2026-08-16 ~23:10. Home LAN, en0 (Wi-Fi) 192.0.2.64. NordVPN IKEv2
up throughout (Nord-off rows NOT MEASURED — the two Shortcuts do not exist
yet; irrelevant to the verdict, see below). Tailscale toggled via
`lib/tailscale-ctl.sh`.

Precondition found already satisfied: `networksetup -getsearchdomains Wi-Fi`
→ `local`. `scutil --dns` shows it merged into the live configuration
(`search domain[0] : local` on the en0 resolver) alongside Tailscale's
`tailXXXX.ts.net` while Tailscale runs.

## State A — Tailscale on, Nord IKEv2 on

| Measurement | Result |
|---|---|
| resolver #1 search list, in order | `tailXXXX.ts.net`, `local` |
| bare `streamy` (5×) | 100.64.10.4; 0.00–0.01 s |
| bare `mac-mini` (5×) | 100.64.10.65; 0.00–0.01 s |
| TCP via bare names | streamy:5000 ok; mac-mini:22 ok |
| tailnet-only name `phone` (no mDNS) | 100.64.10.100 in 0.03 s — no `.local` detour |
| `doesnotexist.local` (away-penalty proxy, 5×) | **10.01–10.02 s** each (mDNS negative timeout) |

Search order is favourable (Tailscale's suffix first), and the 10 s cost of a
failed `.local` lookup would only ever be paid if `local` were actually
tried — which, per State B, it is not.

## State B — Tailscale OFF, Nord IKEv2 on (the state this epic is about)

| Measurement | Result |
|---|---|
| resolver #1 | nameserver 103.86.96.100 (Nord IKEv2); search list: `local` only |
| bare `streamy` (5×) | **no answer, 0.00–0.01 s** |
| bare `mac-mini` (5×) | **no answer, 0.00–0.01 s** |
| TCP via bare names | streamy:5000 FAIL; mac-mini:22 FAIL |
| `streamy.local` (system resolver) | 192.0.2.4 (mDNS works fine) |
| web | 200 (via Nord) |
| tailnet-only name, TS off | no answer in **0.13 s** — NOT the 10 s mDNS timeout |
| `bin/dns-verify.sh` | 4 FAIL (names/services), 2 SKIP (staleness) — same as before the search domain |

## Verdict: **NOT VIABLE**

macOS does **not** apply `local` as a unicast search suffix. With `local` the
only entry in the search list, bare `streamy` returns no answer in ~10 ms —
not the ~10 s an attempted `streamy.local` mDNS query would take when the
host is absent, and not the LAN address it would return when the host is
present (it is present). The tailnet-only name failing in 0.13 s rather than
10 s confirms no `.local` expansion is attempted at all.

`dns-sd -E` / `dns-sd -F` show why: mDNSResponder lists `local` as the
recommended Bonjour **registration/browsing** domain. The same word is a
Bonjour zone, deliberately excluded from search-path synthesis, so
`<name>` never becomes `<name>.local` via the search list. Setting `local`
as a search domain is harmless and does nothing.

## Side effects

None observed: `localhost` and Tailscale-up bare names unchanged; the
setting adds no latency to any lookup because it is never consulted.

## Consequence for ADR-003

The zero-daemon, zero-IP mechanism is off the table. The remaining general
mechanisms both require *something* to answer for the bare name when
Tailscale is down:

- **(B) dynamic `/etc/hosts`** — a marked block, LAN IPs when Tailscale is
  down, tailnet IPs (or removed, letting MagicDNS answer) when up. Needs a
  root write on each flip → privilege model is the human's decision.
- **(B′) static `/etc/hosts` with LAN IPs only for hosts that are always at
  home** — no daemon, no flipping: `/etc/hosts` is consulted before any
  resolver, so bare `streamy` → 192.0.2.4 in every state, including
  Tailscale-up-at-home (still reachable, direct LAN, verified 8 ms earlier
  in this project). Cost: **away with Tailscale up, the LAN IP is wrong and
  `/etc/hosts` shadows MagicDNS** — bare names would break exactly when
  travelling. Only acceptable if bare names are needed at home only.
- **(C) a local unicast resolver for a private suffix** (e.g. `/etc/resolver/home`
  → dnsmasq answering `streamy.home` from a hosts-style file, plus `home` as
  a *unicast* search domain, which macOS does honour) — general, no
  hard-coding beyond one file, no root at runtime after install, but adds a
  daemon (brew dnsmasq or a launchd script). Search order would put
  `tailXXXX.ts.net` first while Tailscale is up, so tailnet names still
  win there. This is the "better approach than the hosts file" if the human
  wants both generality and away-safety.

Measured facts that constrain the choice: `/etc/hosts` shadowing MagicDNS
is only harmful away; a unicast search domain *is* applied to bare names
(that is exactly how `tailXXXX.ts.net` works today); mDNS `.local` is not.

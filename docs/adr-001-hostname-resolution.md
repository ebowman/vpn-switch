# ADR-001: Hostname Resolution Strategy for streamy / mac-mini

- **Status:** Superseded by ADR-002 (2026-08-16)
- **Date:** 2026-08-15
- **Supersedes:** nothing (first ADR in this repo)

## Superseded (2026-08-16)

The `/etc/resolver` decision below (Section 2) was **never applied** — it is
superseded before installation, not after a failed rollout. The reason is not
a flaw in the mechanism; it is that the underlying collision this ADR was
built to work around turned out to be an artifact of the **NordVPN app's**
NordLynx tunnel extension, not of NordVPN itself. That extension installs a
resolver at `100.64.0.2`, inside the CGNAT range Tailscale claims, which is
what black-holes DNS whenever both are up (see Context, below, for the
mechanism). NordVPN's own IKEv2 servers push a resolver
(`103.86.96.100`/`103.86.99.100`) and a tunnel address (`10.6.0.41` observed)
that sit entirely outside `100.64.0.0/10` — so running NordVPN over a native
IKEv2 configuration profile instead of the app removes the collision at its
source. Measured: with Tailscale up and NordVPN IKEv2 up simultaneously,
bare tailnet names resolve correctly, and disconnecting/reconnecting Nord
makes no difference either way. See **[ADR-002](adr-002-nordvpn-ikev2.md)**
for the decision, the full evidence, and the tradeoffs of the new approach.
The rest of this document — in particular the corrected root-cause mechanism
(nameserver selection driven by primary-service election via the default
route, not by resolver `order` values, and specificity/longest-suffix-match
governing domain-scoped resolvers) — remains accurate and is why the
app-based path fails while the IKEv2 path does not; it is retained below for
that reason, not as an active decision.

## 1. Context

The goal (epic `dns-config-c15`) is that typing the bare hostname `streamy` or
`mac-mini` reaches the right host in every combination of location,
Tailscale, and NordVPN state:

- **A.** Home LAN, Tailscale on, NordVPN off
- **B.** Home LAN, Tailscale on, NordVPN on
- **C.** Home LAN, Tailscale off, NordVPN on/off
- **D.** Away, Tailscale on, NordVPN off
- **E.** Away, Tailscale on, NordVPN on

### Corrected root cause

An earlier framing of this problem stated the cause as "NordVPN's resolver
has no search domain." **That framing is wrong and is retracted.** The
measured behavior is more specific:

NordVPN installs a resolver at `100.64.0.2` (`scutil --dns` resolver #1,
`if_index 30`/`utun11`, `order 104800`). This is distinct from `10.5.0.2`,
which is the **route gateway** for Nord's tunnel — visible in `netstat -rn`
as `default 10.5.0.2 UGScg utun11` — not a nameserver; the two addresses
were previously conflated in this document and that conflation is now
resolved (see Risks, item 5). Tailscale MagicDNS installs a resolver at
`100.100.100.100` on `utun17` with `order 101600`. **[Superseded
explanation — retained for the record, do not rely on it:]** this document
originally reasoned that "a lower order value wins" and that `104800 >
101600` is why Nord's resolver outranks MagicDNS. That comparison is wrong:
those two order values never compete. The real reason Nord's resolver wins
is macOS **primary-service election** — a service is not elected primary
unless it holds a default route (`ip_plugin.c`), NordVPN installs one and
Tailscale does not — and, for domain-scoped resolvers, longest-suffix
specificity is evaluated before `order` (`compareDomain()`,
`BetterMatchForName()`). Evidence: bead `dns-config-c15.3`, comment
2026-08-16 00:04. The observable outcome — **Nord's resolver is used
whenever NordVPN's app is up** — is unchanged.

Critically, Nord's resolver **does** carry the search domain
`tailXXXX.ts.net` — the suffix is not missing. macOS appends the suffix as
expected and issues the query `streamy.tailXXXX.ts.net` — but it sends that
suffixed query to Nord's nameserver (`100.64.0.2`), not to MagicDNS. Nord's
nameserver has no knowledge of tailnet names and returns NXDOMAIN (no
answer). MagicDNS is never consulted for the bare name because it is not the
top-ranked resolver.

**The failure is nameserver selection, not a missing search domain.**

Measured evidence (epic `dns-config-c15`, observed 2026-08-15, en0
192.0.2.64): with NordVPN up, bare `streamy` returned no answer, while
`streamy.tailXXXX.ts.net` returned `100.64.10.4`. This is the direct
proof that the search-domain suffix is applied but is being resolved against
the wrong nameserver.

With NordVPN down, the healthy baseline (`snapshots/ts-on-nord-off.txt`,
captured 2026-08-15) shows MagicDNS's resolver at `order 101400`/`101401` as
the top hit, `streamy` resolving directly to `100.64.10.4`,
`streamy.local` resolving via mDNS to `192.0.2.4`, and
`streamy.tailXXXX.ts.net` also resolving to `100.64.10.4`. All three
forms work when Nord is off; only the bare/FQDN forms are at risk when Nord
is on.

**Confirming datapoint: Tailscale already installs a domain-scoped
resolver of exactly the shape this ADR proposes to make static.** With Nord
down, `scutil --dns` resolver #3 shows `domain : tailXXXX.ts.net.` →
nameserver `100.100.100.100` at `order 101401`. Tailscale creates this
domain-scoped resolver dynamically. This proves the domain-scoped-resolver
*shape* (the mechanism chosen below) works and correctly routes tailnet
queries to MagicDNS — it is not a novel or speculative approach. The open
question is narrower than "does this shape work": it is specifically
**whether a static file, written once to `/etc/resolver/`, survives and
outranks Nord's higher-priority resolver, given that Tailscale's own
dynamically-installed version of this same resolver is the thing most
likely to be clobbered by a Nord reconnect** (see Related: routing
instability, below).

## 2. Decision

**Create `/etc/resolver/tailXXXX.ts.net` containing `nameserver
100.100.100.100`.**

This is a domain-scoped resolver directive: macOS's resolver framework
treats any query ending in `tailXXXX.ts.net` as belonging to this
resolver regardless of interface ordering, and sends it straight to
MagicDNS (`100.100.100.100`) rather than whichever resolver happens to have
the highest-ranked default order at the time.

Rationale for the choice, as settled by the operator: this mechanism
resolves **live** against MagicDNS on every query. It has no cached or
hard-coded IP data to go stale — unlike `/etc/hosts`, which pins specific
`100.x` addresses that will silently break if a node's Tailscale IP ever
changes. The operator explicitly optimized for avoiding hard-coded IPs over
other considerations (including the performance question addressed in
Alternative (a) below).

## 3. Alternatives considered

### (a) `/etc/hosts` pinning `100.x` IPs — REJECTED

Static entries such as:
```
100.64.10.4  streamy
100.64.10.65  mac-mini
```
`/etc/hosts` is consulted before any DNS resolver, so this approach is
immune to resolver-order problems entirely and would work in every scenario
where the pinned IP is reachable, including scenario C (Tailscale off would
simply make the pinned IP unreachable, which is a clean failure rather than
a wrong-answer failure).

The usual objection to this approach is that routing through a `100.x`
Tailscale address instead of a LAN address takes a suboptimal path (relay
instead of direct). **Measurement refuted this objection**: the healthy
baseline snapshot (`snapshots/ts-on-nord-off.txt`) shows Tailscale's status
line for `streamy` as `active; direct 192.0.2.4:41641` — i.e., Tailscale
is already negotiating a **direct** peer-to-peer path over the LAN, not
relaying through DERP, when both machines are on the same network. So the
performance objection to `/etc/hosts` does not hold in the observed
steady state.

Quantitative measurement confirms this qualitative result. `tailscale ping
streamy` reports `pong from streamy (100.64.10.4) via
192.0.2.4:41641 in 8ms` — an 8ms direct round trip, not a relayed one.
ICMP latency to the two candidate addresses over a 3-packet sample is
statistically indistinguishable at the floor:

| Target | min/avg/max (ms) |
|---|---|
| `100.64.10.4` (tailnet) | 5.205 / 26.027 / 67.118 |
| `192.0.2.4` (LAN) | 5.296 / 41.621 / 83.044 |

The minimum latency — the figure least sensitive to transient contention —
is effectively identical (5.205ms vs. 5.296ms). The spread between avg and
max on both rows is consistent with Wi-Fi jitter over a small 3-packet
sample, not a difference in path. There is no measured performance penalty
to routing through the tailnet address on the home LAN.

Despite that, `/etc/hosts` was **rejected for staleness risk alone**: the
IPs are hard-coded, and if a node's Tailscale IP ever changes (re-key,
re-enrollment, tailnet reconfiguration), the entry goes stale silently —
`/etc/hosts` has no mechanism to detect or self-correct this. The operator
weighed that risk above the (refuted) performance concern and rejected this
option.

`/etc/hosts` remains the **unconditional fallback** if the chosen mechanism
((b), below) is found to fail — see Risks, item 4.

### (b) `/etc/resolver/tailXXXX.ts.net` — CHOSEN

See Decision, above.

### (c) `networksetup -setsearchdomains` — REFUTED BY MEASUREMENT

This approach would pin the search domain `tailXXXX.ts.net` on the
Wi-Fi/Ethernet network service, so that it is always appended to bare
queries.

This is refuted by the same measured evidence cited in the Context section:
the search domain **is already being applied**. Nord's resolver (order
104800) already carries `search domain[0]: tailXXXX.ts.net`, which is why
`streamy.tailXXXX.ts.net` resolves correctly even with Nord up. Pinning
the search domain again via `networksetup` cannot fix anything, because the
suffix was never the missing piece — the problem is which nameserver the
suffixed query is sent to. This alternative does not address the actual
root cause and was discarded on that basis.

### (d) NordVPN split-tunnel / Tailscale `ExitNodeAllowLANAccess` — UNEXPLORED

Configuring NordVPN to split-tunnel the `100.64.0.0/10` CGNAT range (so
tailnet traffic bypasses the Nord tunnel entirely), and/or tuning Tailscale's
`ExitNodeAllowLANAccess` setting, is a plausible way to prevent Nord's
resolver and default route from taking priority over Tailscale in the first
place.

This alternative is **not explored or measured** in this ADR. It is flagged
because it directly overlaps with bug `dns-config-lsy` (intermittent
connectivity when NordVPN and Tailscale are both active), which records
`RouteAll=true, ExitNodeAllowLANAccess=false` as the current NordVPN/
Tailscale preference state and identifies route contention between Nord's
default route (`utun11`) and Tailscale's default/`100.64/10` routes
(`utun17`) as a live hypothesis for that bug. If a split-tunnel rule for
`100.64.0.0/10` were applied, it could plausibly fix both the DNS
selection problem in this ADR and the routing bug in `dns-config-lsy`
simultaneously, since both stem from Nord's tunnel outranking Tailscale's
interfaces. This is a hypothesis, not a finding — it has not been tested,
and no claim is made here that it works. It is left as a candidate for
future investigation, most naturally under `dns-config-lsy`.

### (e) `~/.ssh/config` Host aliases — REJECTED as partial

Adding `Host streamy` / `Host mac-mini` aliases with pinned
`HostName` entries to `~/.ssh/config` would fix `ssh streamy` regardless of
DNS state. It was rejected as a general solution because it only covers SSH
traffic. It does not fix the Synology web UI (browser), file shares (SMB/AFP
via Finder), or media streaming (app-level hostname lookups) — all of which
resolve hostnames through the system resolver, not through SSH's own alias
table. It remains a reasonable narrow supplement for SSH workflows but is
not a substitute for the chosen mechanism.

## 4. Scenario behaviour table

| Scenario | Expected behaviour under `/etc/resolver` | Status |
|---|---|---|
| A. Home LAN, Tailscale on, Nord off | Matches the healthy baseline already measured in `snapshots/ts-on-nord-off.txt`: MagicDNS is the top-ranked resolver even without the domain-scoped entry, so bare, `.local`, and FQDN forms all resolve. The domain-scoped entry is redundant here but harmless. | VERIFIED (baseline snapshot, mechanism not yet installed) |
| B. Home LAN, Tailscale on, Nord on | The domain-scoped resolver should route `*.tailXXXX.ts.net` queries to MagicDNS regardless of Nord's higher-priority default resolver, fixing the FQDN form. Whether the bare form also resolves depends on the search domain still being applied on top of the domain-scoped entry (see Risks, item 2). | UNVERIFIED — mechanism not yet installed or tested against a real Nord-up state |
| C. Home LAN, Tailscale off | With Tailscale off, the tailnet addresses are unreachable and the `.local` mDNS names (`streamy.local` → `192.0.2.4`, `mac-mini.local` → `192.0.2.65`) are the only working path, so bare names do NOT work in that scenario under this design. | Behaviour is a direct, unavoidable consequence of the design (MagicDNS cannot be reached if Tailscale itself is off) — not separately re-verifiable beyond the mDNS results already recorded in the baseline snapshot |
| D. Away, Tailscale on, Nord off | Expected to behave the same as scenario A once away from the LAN, since MagicDNS resolution does not depend on being on the home network — only on Tailscale being up. | UNVERIFIED — not capturable at a home desk; requires an away network (e.g., iPhone hotspot) |
| E. Away, Tailscale on, Nord on | Expected to behave the same as scenario B, since the resolver-order conflict is a property of the local machine's resolver configuration, not of network location. | UNVERIFIED — not capturable at a home desk, and additionally blocked on Nord being re-enabled |

## 5. Risks and open questions

1. **The chosen mechanism is UNPROVEN against the actual failure.** No
   measurement yet exists showing that a static `/etc/resolver` entry
   actually outranks Nord's resolver at order 104800 when Nord is up. It
   must also be verified that the entry **survives a NordVPN auto-reconnect**
   — verifying only steady-state Nord-up behavior is insufficient. Bug
   `dns-config-lsy` documents that NordVPN reconnected automatically after a
   ~15-minute pause expired, and that Tailscale's own link monitor reacted to
   the resulting gateway/self-IP change (`portmap: monitor: gateway and self
   IP changed`). The working hypothesis on `dns-config-lsy` is that every
   Nord connect/reconnect event tears down and reinstalls the macOS resolver
   stack underneath a running Tailscale — the same resolver stack this ADR's
   mechanism depends on persisting in. A single steady-state capture with
   Nord already up does not demonstrate that the entry survives that
   teardown/reinstall cycle.

   **NordVPN auto-reconnect was directly observed** (`dns-config-lsy`):
   NordVPN reconnected on its own after a 15-minute pause expired, with no
   manual action. Every such reconnect rebuilds the resolver stack and
   routes underneath a running Tailscale. This is why "survives a Nord
   reconnect" is a **mandatory** test for whichever mechanism is chosen, not
   an optional extra — verifying only steady-state Nord-up behavior is
   insufficient, because steady-state is not the condition that is
   suspected of breaking things.

2. **Whether `/etc/resolver` fixes the bare name, not just the FQDN, is
   untested.** `/etc/resolver` entries are domain-scoped, so they
   authoritatively fix the FQDN path (`streamy.tailXXXX.ts.net`) — any
   query already ending in that domain will be routed to MagicDNS regardless
   of default resolver order. Whether the entry additionally fixes the
   **bare** name depends on the search domain (`tailXXXX.ts.net`) still
   being applied to bare queries and the resulting suffixed query then
   correctly hitting the domain-scoped resolver. The healthy baseline shows
   Nord's resolver does carry that search domain, so the bare name plausibly
   works too — but this is a plausibility argument, not a measurement, and
   must be tested with Nord up rather than assumed. If the bare name still
   fails with `/etc/resolver` in place, that is a material finding requiring
   a return to the human, not a silent fallback to a different mechanism.

3. **Tailnet instability makes DNS measurements unreliable while Nord is
   up.** Cross-referencing `dns-config-lsy`: NordVPN auto-reconnect is
   suspected of tearing down the resolver stack, and Tailscale has separately
   been observed hitting a `mapresponse-timeout` (no netmap from the
   coordination server for 2m6s) while Nord is up. A DNS test run during such
   a window measures a degraded tailnet, not the steady Nord-up state, and
   any Nord-up verification of this ADR's mechanism must record whether a
   netmap timeout was active at the time rather than treating a degraded
   capture as normal.

4. **If measurement shows the chosen mechanism fails, the correct action is
   to STOP and return to the human — not to silently substitute
   `/etc/hosts`.** The operator explicitly rejected `/etc/hosts` for
   staleness risk (see Alternative (a)) despite it being technically viable;
   silently reverting to it if `/etc/resolver` underperforms would override
   that decision without authorization. `/etc/hosts` remains available as an
   unconditional fallback, but adopting it requires going back to the human,
   not an autonomous substitution.

### Related: routing instability (`dns-config-lsy`)

Bug `dns-config-lsy` is investigating a separate, but related, fault:
intermittent connectivity loss when NordVPN and Tailscale are both active.
That bug is about routing/transport, not DNS, but it directly bears on how
much this ADR's Nord-up measurements can be trusted, and it shares a
plausible fix with Alternative (d) above. Recovered evidence from that bug:

- **Nord UP:** Tailscale hit a `mapresponse-timeout` — no netmap received
  from the coordination server for 2m6s. This is the **control** connection
  to `controlplane.tailscale.com`, not DNS and not peer data traffic.
- **Nord DOWN baseline:** `tailscale netcheck` reported `UDP true`, nearest
  DERP relay London at 32.8ms; `tailscale status` showed `streamy` as
  `active; direct 192.0.2.4:41641` — a direct peer path, not relayed.
- **PMTU bisect (Nord down), tailnet address `100.64.10.4`:** payload size
  1252 PASS, 1253 FAIL — an exact boundary that matches `utun17`'s 1280
  MTU minus 28 bytes of IP/ICMP header. Control probe over the **LAN**
  address (`192.0.2.4`) passed at 1472 bytes, confirming the ceiling is a
  property of the tailnet path, not the host or the local network.
  Interface MTUs: `en0` = 1500, `utun11` (Nord) = 1420, `utun17`
  (Tailscale) = 1280.
- **Interpretation — stated carefully:** 1280 is Tailscale's *normal* MTU
  and everything works fine at it with Nord down, so a small MTU is **not
  itself the bug**. The working hypothesis instead is that Nord breaks
  **path-MTU discovery** while active, creating a black hole where
  handshakes (small packets) succeed but full-size segments are silently
  dropped. This is marked **UNCONFIRMED** — it requires a Nord-up
  measurement (the bisect above was captured with Nord down) to test
  whether the boundary shifts or large transfers hang under Nord.
- **Operational consequence for this ADR:** an unstable tailnet makes DNS
  measurements unreliable — a capture taken during a netmap timeout or a
  routing disruption reflects a degraded tailnet, not the steady Nord-up
  state. `dns-config-c15.6` (the matrix verification run) must record
  tailnet health (netcheck / status / any active timeout) alongside every
  DNS result, not just the DNS result in isolation.
- **Shared candidate fix:** NordVPN split-tunnelling `100.64.0.0/10` may
  fix **both** the routing instability in `dns-config-lsy` and the DNS
  nameserver-selection problem in this ADR, since both stem from Nord's
  tunnel/resolver outranking Tailscale's. See Alternative (d), above — this
  remains a hypothesis, not a finding, and is not applied by this ADR.

**Resolved: the `10.5.0.2` / `100.64.0.2` discrepancy.** An earlier version
of this ADR flagged these two addresses as an inconsistency in Nord's
recorded resolver IP. This is no longer an open question. Both values are
real and were observed correctly, but they refer to two different things:
`10.5.0.2` is Nord's tunnel **route gateway** (`netstat -rn`: `default
10.5.0.2 UGScg utun11`); `100.64.0.2` is Nord's **DNS nameserver**
(`scutil --dns` resolver #1, `if_index 30`/`utun11`, `order 104800`). The
epic description conflated the two. Throughout this ADR, `100.64.0.2` is
cited as Nord's resolver; `10.5.0.2` is cited only where the route gateway
specifically is meant (see Context, above).

## 6. Consequences

- `/etc/resolver/` does not currently exist on this Mac and must be created:
  `sudo mkdir -p /etc/resolver` before the file can be written. This is
  in scope for `dns-config-c15.4` (the install script), which must apply
  this configuration idempotently and reversibly — re-running it should not
  duplicate or corrupt the file, and it must be uninstallable.
- `dns-config-c15.4` must write `/etc/resolver/tailXXXX.ts.net` containing
  exactly `nameserver 100.100.100.100`, using `sudo` where required, and
  must be safe to re-run (idempotent) and safe to revert (reversible).
- `dns-config-c15.5`/`dns-config-c15.6` (verification script and matrix run)
  must specifically exercise the two currently-unverified claims above: (a)
  that the entry outranks Nord's resolver in a real Nord-up state, including
  across a deliberate Nord reconnect, and (b) that the bare name — not just
  the FQDN — resolves correctly once the entry is in place. Both scenarios D
  and E (away-from-home) remain unverifiable from the home desk and must be
  explicitly marked as such until an away-network capture (e.g., iPhone
  hotspot) is performed.
- Because scenario C has no DNS-level fix under this design, any runbook or
  documentation produced downstream (`dns-config-c15.7`) must tell the
  operator to use `.local` mDNS names, not bare tailnet names, when
  Tailscale is off.

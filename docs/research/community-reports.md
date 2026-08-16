# Community Reports: VPN DNS Resolvers Inside Tailscale's CGNAT Range

Research output for bead `dns-config-seo.2`. Input: the confirmed root cause in `dns-config-lsy`.

## The problem being searched for

NordVPN configures `100.64.0.2` as a system resolver on macOS. That address is inside
`100.64.0.0/10` — the RFC 6598 CGNAT range Tailscale claims in full and routes via its
`utun` interface. With both running, `route -n get 100.64.0.2` returns Tailscale's
interface, so queries to Nord's nameserver are routed into the tailnet and black-holed.
Nord installs that resolver ahead of MagicDNS (order 104800 vs 101600), so *all* DNS
fails and the machine appears to have no network. Tailscale reports `mapresponse-timeout`.

## Summary of findings

**No report was found describing our exact case** — NordVPN's `100.64.0.2` resolver
colliding with Tailscale's CGNAT claim on macOS. Nobody appears to have published this
specific diagnosis.

**However, the general failure mode is well documented and independently confirmed.** The
*structural* bug — "a resolver address inside `100.64.0.0/10` becomes unreachable once
Tailscale claims the range, and DNS dies entirely" — is reported and *confirmed fixed* in
at least two independent cases: Mullvad VPN's content-blocker DNS (macOS), and AliCloud's
internal `100.100.2.x` resolvers (Linux). Those are the same bug with a different vendor
supplying the in-range address.

Counts:

- **2 reports that are structurally the same bug** (in-range DNS resolver → total DNS
  failure), with confirmed working fixes: Mullvad/macOS, AliCloud/Linux.
- **1 report of a VPN provider explicitly placing DNS inside `100.64.0.x`**, matching
  Nord's address choice pattern: Mullvad content blockers.
- **~6 adjacent reports** where the CGNAT collision is real but manifests as routing or
  firewall breakage rather than resolver breakage.
- **0 reports** naming NordVPN's `100.64.0.2` resolver.
- **0 reports** of this on macOS with NordVPN specifically.

---

## Relevant reports

### A. Structurally identical: in-range resolver causes total DNS failure

#### A1. Mullvad content-blocker DNS collides with Tailscale CGNAT range (macOS)

- **URL:** https://github.com/tobomobo/mullvad-tailscale-macos
- **Date:** no release date published; repo is recent (2026)
- **Platform:** macOS (exclusively)
- **Symptom:** DNS stops working when Mullvad's content-blocker DNS is enabled alongside
  Tailscale. Listed in the README's failure table as "Mullvad content blockers stop DNS."
- **Cause correctly identified:** **Yes.** README states: *"Mullvad must use its default
  DNS because its content-blocker DNS addresses overlap Tailscale's address range."*
- **Workaround:** Two parts — (1) use Mullvad's *default* DNS, never the content-blocker
  DNS addresses; (2) a PF anchor whitelisting `100.64.0.0/10` and `fd7a:115c:a1e0::/48`
  on Tailscale's detected `utun` interface, plus a watcher daemon that reapplies the
  anchor when Mullvad rewrites its rules.
- **Confirmed working:** Yes — the repo exists as a packaged, maintained fix with a
  self-repairing watcher, i.e. the author runs it.
- **Relevance judgement:** **Direct structural match.** Same OS (macOS), same range, same
  mechanism (a commercial VPN placing its resolver inside `100.64.0.x`), same outcome
  (DNS dies). Only the vendor differs. This is the single most useful report found.

#### A2. Tailscale blocks CGNAT-range DNS servers; all resolution fails (Linux)

- **URL:** https://nyan.im/p/troubleshooting-tailscale-network-en
- **Date:** 13 May 2022
- **Platform:** Linux (AliCloud Beijing VPS, Tailscale exit node)
- **Symptom:** "No internet." `curl` to an IP worked but every domain name failed to
  resolve. Initially looked like a pure DNS bug.
- **Cause correctly identified:** **Yes**, after investigation. The provider's internal
  DNS servers are `100.100.2.136` and `100.100.2.138` — inside `100.64.0.0/10`. Tailscale
  installs a firewall rule dropping traffic to that CIDR to prevent CGNAT conflicts, so
  the resolvers became unreachable and every lookup failed. Internal apt mirror
  (`100.100.2.148`) was collateral.
- **Workaround:** Delete the offending rule with `iptables -D`, or start Tailscale with
  `--netfilter-mode=off` (noted as having security caveats).
- **Confirmed working:** **Yes** — author verified DNS queries returned correct answers
  after removing the rule.
- **Relevance judgement:** **Direct structural match**, different platform. The resolver
  is supplied by a cloud provider rather than a VPN, but the causal chain is identical:
  resolver inside the /10 → Tailscale claims the /10 → resolver unreachable → all DNS
  fails → user perceives "no network." Note the Linux mechanism is a *firewall drop*
  where ours is a *route steal*; the symptom is the same.

#### A3. Mullvad + Tailscale DNS deadlock (Linux)

- **URL:** https://foss.life/notes/2026/fix-mullvad-tailscale-deadlock/
- **Date:** published 13 Jun 2026, updated 15 Jun 2026
- **Platform:** Linux (systemd-resolved, nftables, NetworkManager)
- **Symptom:** MagicDNS names resolved but traffic "hung infinitely." `ip route get
  <tailscale-ip>` showed packets leaving via `wlan0` instead of `tailscale0`.
- **Cause correctly identified:** **Yes** — both VPNs fighting for DNS control in
  systemd-resolved, plus Mullvad's nftables rules preventing Tailscale traffic from
  reaching the right interface. Author used the route-lookup diagnostic (`ip route get`)
  that is the Linux analogue of our `route -n get 100.64.0.2`.
- **Workaround:** Assign a DNS routing domain to Mullvad; mark Tailscale traffic with
  Mullvad exclusion marks in nftables; NetworkManager dispatcher script to keep `.ts.net`
  resolution pointed at Tailscale.
- **Confirmed working:** **Yes** — *"everything now works even when Mullvad reconnects."*
- **Relevance judgement:** **Relevant.** DNS is squarely implicated and the diagnostic
  method matches ours (route lookup revealing the wrong interface). Slightly different in
  that the resolver-address overlap is not the headline; resolver *priority* and
  interface routing are.

### B. Same range collision, DNS implicated but not the resolver address

#### B1. Tailscale issue #1381 — "Better interop with other users of 100.64.0.0/10"

- **URL:** https://github.com/tailscale/tailscale/issues/1381
- **Date opened:** 22 Feb 2021 — **still open**
- **Platform:** Linux, Windows, macOS, iOS, ChromeOS
- **Symptom:** On Linux, anti-spoofing rules drop `100.64.0.0/10` traffic not originating
  from `tailscale0`. On Windows/macOS/iOS, overlay traffic risks being routed out the
  underlay interface.
- **Cause correctly identified:** Yes — this *is* the upstream tracking issue for the
  class of bug.
- **Workaround:** None accepted. Issue is still awaiting a decision on desired behaviour.
- **Confirmed working:** N/A.
- **Relevance judgement:** **Relevant as upstream context.** No commenter in the fetched
  content names a VPN provider using an in-range DNS resolver. Its value is that it shows
  Tailscale has known about the general interop problem for **five years without shipping
  a general fix** — which bears directly on how durable any workaround needs to be.

#### B2. Mullvad app issue #5921 — cannot reach `100.64.0.0/10` with Mullvad up

- **URL:** https://github.com/mullvad/mullvadvpn-app/issues/5921
- **Date:** 7 Mar 2024 — **closed**
- **Platform:** Linux
- **Symptom:** With Mullvad enabled, Tailscale nodes become unreachable.
- **Cause correctly identified:** **Yes** — reporter identified that `100.64.0.0/10`,
  which Tailscale uses and cannot change, is absent from Mullvad's "Local network
  sharing" allowed-subnets list. Mullvad's allowlist covers RFC1918 and `fc00::/7` but
  **not** `100.64.0.0/10`.
- **Workaround:** None recorded in the issue; closed without a documented Mullvad fix.
- **Confirmed working:** N/A.
- **Relevance judgement:** **Relevant but routing-only.** DNS is not discussed and no
  `100.64.0.x` DNS address is named. Included because it documents the vendor-side cause
  (allowlist omits the /10) that produces the DNS variant in report A1.

#### B3. Tailscale issue #17070 — Mullvad breaks recursive DNS

- **URL:** https://github.com/tailscale/tailscale/issues/17070
- **Date:** 9 Sep 2025 — **open**, labelled `dns`, `mullvad`, `OS-linux`
- **Platform:** Linux (Debian 12), Pi-hole + Unbound
- **Symptom:** Enabling Mullvad on Tailscale stops the local recursive resolver getting
  authoritative answers from root servers.
- **Cause correctly identified:** **No.** CGNAT collision is not named. `--accept-dns=false`
  did not help.
- **Workaround:** Only "disable Mullvad."
- **Confirmed working:** No fix; issue open with no maintainer response.
- **Relevance judgement:** **Symptom-match, cause not identified.** DNS is clearly
  implicated and Mullvad is the trigger, but the reporter never reaches the range
  collision. Recorded per the bead's instruction to keep undiagnosed symptom-matches.

#### B4. NordVPN + Tailscale on Linux (community gist)

- **URL:** https://gist.github.com/dafaqboomduck/a64ae31388bc12105c0b4621e3004794
- **Date:** recent; NordVPN 4.5.0, Tailscale 1.96.4
- **Platform:** Ubuntu Server 24.04 LTS, NordLynx
- **Symptom:** Four distinct problems — Nord disables IPv6 system-wide; Nord's firewall
  drops Tailscale control-plane traffic to `controlplane.tailscale.com:443`; kill switch
  deadlocks at boot **when DNS resolution fails during startup**; service start-order race
  causes routing conflicts.
- **Cause correctly identified:** **Partially.** The author knows `100.64.0.0/10` is
  "the Tailscale CGNAT range" and allowlists it in Nord, but **never identifies it as
  colliding with any NordVPN DNS resolver**. The DNS advice runs the other direction:
  point Nord at Tailscale's resolver `100.100.100.100` so MagicDNS names resolve.
- **Workaround:** `nordvpn set firewall disabled`, `nordvpn set killswitch disabled`,
  re-enable IPv6 via sysctl, allowlist port 41641 and subnet `100.64.0.0/10`, and a
  `tailscale-then-nord.service` unit to force start ordering.
- **Confirmed working:** Claimed to be "based on real debugging," but **no explicit
  post-fix confirmation**.
- **Relevance judgement:** **Closest NordVPN-specific document found, but not our bug.**
  It is the same pair of products and DNS appears, yet the in-range-resolver collision is
  absent. Notably, this author's fix (`nordvpn set dns 100.100.100.100`) would
  *incidentally* resolve our issue by displacing `100.64.0.2` — without the author
  realising why.

#### B5. Tailscale + ProtonVPN coexistence guide

- **URL:** https://hstu.net/blog/using-tailscale-alongside-another-vpn/
- **Date:** 25 Oct 2023
- **Platform:** Linux (Ubuntu Server) primary; macOS and Windows tested
- **Symptom:** No conflict observed on macOS; **did** conflict on Windows; cannot run both
  on iOS.
- **Cause correctly identified:** Partially — routing over `100.64.0.0/10` and DNS both
  needed explicit handling.
- **Workaround:** `tailscale up --accept-dns=false --advertise-exit-node`; CoreDNS split
  routing `.ts.net` → `100.100.100.100` and everything else → ProtonVPN DNS;
  `ip route add 100.64.0.0/10 dev tailscale0`; disable IPv6 on the WireGuard interface.
- **Confirmed working:** **Yes**, author reports it working with negligible speed impact,
  though "80% of the way there."
- **Relevance judgement:** **Relevant.** Establishes `--accept-dns=false` + split DNS as a
  pattern, and that ProtonVPN does **not** place a resolver inside the /10 (the macOS case
  showed no conflict).

#### B6. Tailscale CGNAT conflict with upstream infrastructure

- **URL:** https://ysun.co/tscgnat/
- **Date:** 1 Nov 2025
- **Platform:** Linux (NixOS, nftables)
- **Symptom:** A routing daemon could not reach its upstream BGP router, whose address is
  in `100.100.0.0/24` — inside the /10 Tailscale drops.
- **Cause correctly identified:** **Yes.**
- **Workaround:** Patch `createDropOutgoingPacketFromCGNATRangeRuleWithTunname()` so the
  nftables rule reads `100.64.0.0/10 ip saddr != 100.100.0.0/24`, carving an exception.
- **Confirmed working:** Author shows the resulting rules working, but frames it as a
  "hack," not an upstream solution.
- **Relevance judgement:** **Relevant as precedent** for "carve a specific address out of
  Tailscale's blanket CGNAT claim" — the same shape of fix our case needs, but Linux
  firewall-level rather than macOS route/resolver-level.

#### B7. Shrinking Tailscale's IP pool to avoid the collision

- **URL:** https://dev.to/chillaranand/tailscale-resolving-cgnat-100xyz-conflicts-56lf
  (also https://avilpage.com/2024/09/tailscale-cgnat-conflicts-resolution.html)
- **Date:** published 7 Sep 2024, updated 3 Nov 2024
- **Platform:** Linux
- **Symptom:** A Tailscale node joining a campus network that itself uses `100.64.0.0/10`
  loses connectivity to local network resources.
- **Cause correctly identified:** Yes (range overlap), though DNS vs routing is not
  separated.
- **Workaround:** Set an ACL `"ipPool": ["100.100.96.0/20"]` to shrink Tailscale's
  assignment range, **plus** manual iptables edits — because a known Tailscale bug means
  the `ipPool` setting alone does not narrow the dropped range.
- **Confirmed working:** **Not confirmed.** Author explicitly notes the ACL fix alone
  fails and the iptables workaround is required; no final success confirmation.
- **Relevance judgement:** **Relevant with a caution.** This documents that the obvious
  "just make Tailscale use less of the /10" fix **does not work** — Tailscale still
  claims/drops the full /10 regardless of `ipPool`. Directly relevant to evaluating our
  own candidate fixes.

### C. Official vendor documentation

#### C1. Tailscale — "Can I use Tailscale alongside other VPNs?"

- **URL:** https://tailscale.com/docs/reference/faq/other-vpns
- **Position:** *"In most cases, you can't use Tailscale alongside other VPNs without a
  workaround."* Explicitly acknowledges: *"If the other VPN uses IP addresses from the
  Carrier-Grade NAT (CGNAT) range (`100.64.0.0` through `100.127.255.255`) that Tailscale
  uses, they will conflict."*
- **Officially recommended workarounds — exactly two:** (1) userspace networking mode
  (SOCKS5 proxy, no network interface); (2) split tunnels / restricted nameservers.
- **Names no specific VPN provider.** Mentions Mullvad only as an exit-node partner.

#### C2. Tailscale — "Troubleshoot CGNAT conflicts"

- **URL:** https://tailscale.com/docs/reference/troubleshooting/network-configuration/cgnat-conflicts
- **Position:** Offers exactly **one** remedy: disable IPv4 in the tailnet, via the
  `"disable-ipv4"` node attribute (per-target or tailnet-wide `"*"`). Warns this blocks
  access to IPv4-only resources.
- **Notably absent:** no mention of DNS resolvers inside the range, no split DNS, no
  `--netfilter-mode`, no way to narrow Tailscale's claimed range. The official answer to
  "something I need lives in `100.64.0.0/10`" is essentially "stop using IPv4."

#### C3. Tailscale — "Reserved IP addresses"

- **URL:** https://tailscale.com/docs/reference/reserved-ip-addresses
- **Position:** Documents `100.64.0.0/10` as "the CGNAT range Tailscale uses for device IP
  addresses" and `100.100.100.100` (Quad100) as a device-local resolver whose traffic
  "stays on the local device."
- **Gap worth noting:** the page **never states** that Tailscale claims the *entire* /10
  or that other addresses in it become unreachable. That undocumented behaviour is exactly
  what bites users in reports A1, A2 and B6.

---

## Other VPN providers: is this Nord-specific?

**No. This is a broad pattern, not a NordVPN quirk.** Providers placing infrastructure
inside `100.64.0.0/10`:

| Provider | In-range address | Condition | DNS affected | Evidence |
|---|---|---|---|---|
| **NordVPN** | `100.64.0.2` | default resolver on macOS | **Yes** | our own measurement (`dns-config-lsy`); no public report found |
| **Mullvad** | `100.64.0.x` (bitmask per blocker category) | content blockers enabled | **Yes** | A1, and Mullvad's allowlist omits the /10 (B2) |
| **AliCloud** | `100.100.2.136`, `100.100.2.138` | always, internal DNS | **Yes** | A2 |
| **Various VPS/BGP upstreams** | e.g. `100.100.0.0/24` | provider infrastructure | routing | B6 |
| **ISPs using real CGNAT** | anywhere in /10 | ISP-dependent | varies | C1, C2 |
| **ProtonVPN** | none found | — | no | B5 — macOS showed no conflict |

Implications for durability of any fix:

1. **The address choice is not stable.** Mullvad's in-range DNS address *varies by
   content-blocker category* (it is described as a bitmask). A fix hard-coded to
   `100.64.0.2` handles today's Nord but nothing else. Prefer a fix that handles *any*
   resolver inside the /10, or at minimum detects the address dynamically.
2. **Vendors keep choosing this range on purpose.** `100.64.0.0/10` is attractive to VPN
   vendors precisely because it is non-RFC1918 and unlikely to clash with a home LAN.
   Tailscale's claim on it is the anomaly from the vendors' point of view, so expect new
   collisions rather than vendors migrating away.
3. **Neither side is fixing it upstream.** Tailscale #1381 has been open since Feb 2021
   with no resolution; Mullvad #5921 was closed without a documented fix. Plan for a
   local workaround to be permanent, not a stopgap.

---

## Consensus

### Fixes most often reported as WORKING

1. **Stop the other VPN from using an in-range address — change its DNS setting.**
   The most reliable fix across reports. Mullvad: use default DNS instead of
   content-blocker DNS (A1, confirmed). Nord on Linux: `nordvpn set dns 100.100.100.100`
   (B4 — which would incidentally fix our bug). This attacks the collision at its source
   and needs no privileged network surgery.
2. **Explicitly carve the needed address out of Tailscale's blanket CGNAT claim.**
   Confirmed working on Linux via `iptables -D` on the drop rule (A2, confirmed) and via
   a patched nftables `saddr !=` exception (B6). The macOS equivalent is a PF anchor
   whitelisting the range on Tailscale's `utun` (A1, confirmed).
3. **Split DNS: route `.ts.net` to `100.100.100.100`, everything else to the other VPN's
   resolver.** Confirmed working with ProtonVPN via CoreDNS (B5) and with Mullvad via a
   systemd-resolved routing domain (A3).
4. **Force start ordering — bring Tailscale up before the other VPN** (B4). Reduces
   route-table races, though not independently confirmed.
5. **Add a watcher that reapplies the fix** (A1). Every report where the other VPN
   rewrites firewall/DNS state on reconnect found the fix decayed without one. A3 also
   only declared success once reconnects were handled.

### Fixes most often reported as NOT working

1. **Shrinking Tailscale's assigned range via ACL `ipPool`.** Explicitly documented as
   insufficient (B7): Tailscale still claims and drops the full `/10` regardless. Do not
   rely on this.
2. **`--accept-dns=false` alone.** Failed to fix DNS in B3; in B5 it only worked as part
   of a full CoreDNS split-DNS setup. It stops Tailscale *setting* DNS but does not stop
   it *claiming the range* — which is the actual problem in our case.
3. **Tailscale's official CGNAT remedy, "disable IPv4."** (C2) Nobody in any community
   report adopted it. It trades the collision for loss of all IPv4-only access.
4. **Userspace networking mode** (C1). Officially recommended, but absent from every
   confirmed community fix — it sacrifices the normal `utun` path that makes Tailscale
   useful on a workstation.
5. **"Just disable the other VPN."** The only remedy reached in B3, and the implicit
   advice in several search summaries. Not a fix.

### Consensus verdict for our case

The single fix with the strongest evidence, on the right platform, against a commercial
VPN with a resolver inside `100.64.0.x`, is **A1's pattern**: prevent the other VPN from
installing an in-range resolver at all, and if it insists, whitelist the range on
Tailscale's `utun` and add a watcher because the VPN will re-clobber it. For NordVPN
specifically, the direct analogue of A1's "use Mullvad's default DNS" is to replace the
`100.64.0.2` resolver with an out-of-range address — the Nord Linux gist (B4) shows Nord
does accept a custom DNS setting, though whether the macOS client exposes the same control
is **not established by any source found and needs verification against our own setup**.

---

## Exact search queries run

Via WebSearch (US region), 16 Aug 2026:

1. `tailscale 100.64.0.0/10 conflict vpn dns`
2. `nordvpn 100.64.0.2 dns tailscale`
3. `tailscale nordvpn no internet dns broken macOS`
4. `tailscale mapresponse-timeout vpn dns`
5. `reddit tailscale nordvpn dns not working both installed`
6. `VPN DNS server 100.64.0.0/10 CGNAT range Proton Mullvad Surfshark conflict tailscale`
7. `"100.64.0" mullvad content blocker DNS tailscale conflict does not resolve`
8. `tailscale forum nordvpn dns 100.64 conflict resolver`
9. `nordvpn meshnet 100.64.0.0/10 tailscale overlap conflict`
10. `site:news.ycombinator.com tailscale CGNAT 100.64 conflict VPN`
11. `superuser serverfault tailscale VPN DNS 100.64 resolver unreachable route conflict`
12. `protonvpn tailscale 100.64 CGNAT DNS conflict no internet`
13. `macOS tailscale utun route 100.64 VPN DNS resolver scutil order breaks all DNS`
14. `"r/Tailscale" OR "r/nordvpn" reddit both VPNs installed internet stops working DNS 100.64`
15. `nordvpn nordlynx DNS server address 103.86.96.100 or 100.64.0.2 meshnet resolver`
16. `tailscale another VPN pushes DNS server inside CGNAT range all DNS queries blackholed`

Pages fetched in full: tailscale/tailscale#1381, #13256, #17070; mullvadvpn-app#5921;
tailscale.com FAQ other-vpns, cgnat-conflicts, reserved-ip-addresses;
github.com/tobomobo/mullvad-tailscale-macos; foss.life Mullvad deadlock note;
dafaqboomduck gist; dev.to CGNAT conflicts; ysun.co/tscgnat; nyan.im troubleshooting;
hstu.net Tailscale-alongside-VPN; tongfamily.com macOS DNS post.

---

## Coverage gaps and caveats

- **Hacker News item 45785709 ("De-escalating Tailscale CGNAT conflict," ~Nov 2025) could
  not be fetched** — three attempts all returned HTTP 429. The linked article itself
  (`ysun.co/tscgnat`) *was* fetched and is recorded as B6; only the comment thread is
  unread. Worth a retry later in case commenters mention VPN DNS inside the range.
- **Reddit yielded nothing directly usable.** Queries 5 and 14 returned no r/Tailscale,
  r/nordvpn or r/VPN threads implicating DNS or the CGNAT range. The nearest hits were
  about Android's one-VPN-at-a-time restriction, which is a different problem.
- **Stack Exchange (Super User / Server Fault) yielded nothing relevant** (query 11).
- **The official Tailscale forum (forum.tailscale.com) surfaced no matching threads**
  across queries 1, 3, 8 — search consistently routed to the docs site instead.
- **NordVPN's published DNS addresses are `103.86.96.100` and `103.86.99.100`** (query 15,
  from NordVPN Meshnet documentation). `100.64.0.2` is **not documented publicly** by
  NordVPN as a resolver address. This strengthens the finding that our case is
  undocumented, and suggests `100.64.0.2` is a Meshnet-related or client-internal address
  rather than a published resolver.

## How relevance was judged

Reports were counted only where **DNS resolution or the `100.64.0.0/10` range was
explicitly implicated**. Applying the bead's false-match warning, the following were
found and **excluded**:

- **tailscale/tailscale#13256** ("FR: Allow use of Mullvad DNS Content Blockers,"
  Aug 2024, closed) — despite matching search terms, it is a pure feature request about
  iOS content blocking with no CGNAT or DNS-failure discussion. Fetched and discarded.
- **Exit-node and split-tunnelling posts** (e.g. "Setting up a Tailscale Exit Node through
  NordVPN," paulwelty.com "Linux exit node pattern") — these are about deliberately
  chaining the two VPNs, a different problem. Excluded.
- **Android one-VPN-at-a-time reports** — an OS limitation, not an address collision.
- **Generic Tailscale macOS DNS bugs** (#16466 resolv.conf not restored, #14867 post-sleep
  DNS loss, #13511 firewall/UDP lockup, #9479, #13423, #15512) — real macOS DNS bugs, but
  none involves a second VPN or an in-range resolver. Excluded as a different fault.
- **SEO content farms** (acciyo.com, healthlinemags.com, medical-review.net, scom2025.org,
  overfl0wed.com) — several appear in results for nearly every query with near-identical
  generated text. Not community reports; treated as noise and not cited as evidence.

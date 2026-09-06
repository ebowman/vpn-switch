# Technical Background: CGNAT Allocation and macOS Resolver Priority

*Addresses and the tailnet name in this document are documentation placeholders (RFC 5737 192.0.2.0/24 for the LAN, 100.64.10.0/24 inside the CGNAT range for the tailnet, tailXXXX.ts.net); the measurements and their relative values are real.*

- **Bead:** `dns-config-seo.3`
- **Date:** 2026-08-16
- **Status:** Desk research. **Nothing in this document was measured on the live
  system.** Empirical verification belongs to `dns-config-c15.4` / `c15.6`.
- **Target system:** Darwin 25.5.0 (macOS 26.5). The locally-installed
  `resolver(5)` man page is stamped `macOS 26.5 / November 23, 2022`.

## 0. Source reliability ranking

Claims below are tagged with a source tier. This matters because macOS resolver
behaviour is poorly documented officially, and the good material is unevenly
reliable.

| Tier | Meaning | Used here |
|---|---|---|
| **A1** | Apple primary: man pages on *this* machine, Apple developer docs | `man 5 resolver`, `man 8 networksetup`, `man 8 scutil` |
| **A2** | Apple open source: `apple-oss-distributions/configd` | `dnsinfo/dnsinfo.h`, `Plugins/IPMonitor/dns-configuration.c` |
| **A3** | Apple staff statements (Apple Developer Forums, esp. Quinn "The Eskimo!", Apple DTS) | DNS/VPN threads |
| **B** | Vendor documentation (Tailscale, NordVPN) — authoritative about the vendor's own intent, not about macOS |
| **C** | Community blogs, Stack Overflow, GitHub issues — corroborating only |
| **D** | Inference by this author — explicitly labelled |

Two caveats that constrain everything below:

1. **`scutil(8)` never documents the `order` field.** Verified locally:
   `man 8 scutil | grep -c -i order` returns **0**. The man page describes
   `--dns` only as reporting "the current DNS configuration", noting that "the
   first listed resolver(5) configuration is considered to be the 'default'
   configuration" and that supplemental configurations follow. The numeric
   `order` value is therefore **NOT DOCUMENTED in any Apple primary (A1)
   source.** The A2 source-code evidence in §3 is the strongest available.
2. **`resolver(5)` documents `search_order` only in a narrow context** — it is
   introduced as "Only required for those clients that share a domain name with
   other clients." Generalising it into a global priority ranking across
   unrelated resolvers goes beyond what the man page says. See §3.

---

## 1. RFC 6598 — Shared Address Space (100.64.0.0/10)

**Source tier: A-equivalent (IETF Standards Track, BCP 153).**

### What the range is reserved for

- **§1 (Introduction):** the block "will be used to number the interfaces that
  connect CGN devices to Customer Premises Equipment (CPE)."
- **§7 (IANA Considerations):** "The Shared Address Space address range is
  `100.64.0.0/10`."
- **§4 (Use of Shared CGN Space):** "Shared Address Space is IPv4 address space
  designated for Service Provider use with the purpose of facilitating CGN
  deployment."
- **§1:** "Shared Address Space is similar to [RFC1918] private address space in
  that it is not globally routable address space and can be used by multiple
  pieces of equipment." But it immediately qualifies this: "Shared Address Space
  has limitations in its use that the current [RFC1918] private address space
  does not have. In particular, Shared Address Space **can only be used in
  Service Provider networks**."

### What it says about multiple parties on the same host

This is the decisive part, and the answer is: **yes, RFC 6598 anticipates
address collision within the range — but it anticipates it as a routing/NAT
problem, not as a DNS-resolver-selection problem.**

- **§4:** "Devices MUST be capable of performing address translation when
  identical Shared Address Space ranges are used on two different interfaces."

  This is a remarkably close structural match to our situation: two different
  interfaces (`utun11` for Nord, `utun17` for Tailscale) both carrying Shared
  Address Space. The RFC contemplates exactly this topology. But the `MUST` is
  addressed to **CGN/CPE devices performing NAT**, not to a multi-homed client
  host running two VPN clients, and it prescribes *address translation* as the
  remedy. It does not describe how a host should choose between two resolvers
  that both live in the range.

- **§4:** "Because CGN service requires non-overlapping address space on each
  side of the home NAT and CGN, entities using Shared Address Space for purposes
  other than for CGN service, as described in this document, are likely to
  experience problems."

  This is the RFC's explicit warning, and **both vendors are squarely inside
  its scope** — neither Tailscale nor NordVPN is a Service Provider offering CGN
  service. The RFC predicted that non-CGN users of this range would "experience
  problems." Our bug is an instance of precisely that prediction coming true.

- **§4:** "Packets with Shared Address Space source or destination addresses
  MUST NOT be forwarded across Service Provider boundaries. Service Providers
  MUST filter such packets on ingress links."
- **§6 (Security Considerations):** "Similar to other special-use IPv4
  addresses, Shared Address Space does not directly raise security issues." It
  recommends filtering at Service Provider boundaries and excluding the space
  from external DNS zone files.

### Direct answer to the key question

**The RFC anticipates the collision, but not this specific failure mode.** It
foresees (a) identical ranges appearing on two interfaces of one device, and
(b) non-CGN users hitting problems. It does *not* discuss resolver selection,
DNS server placement inside the range, or two userland VPN clients on one host.
Our failure is a **downstream consequence** of the overlap the RFC warned about,
arriving through a mechanism (macOS's resolver ranking) that is entirely outside
the RFC's scope.

---

## 2. Verdict on RFC conformance

**Verdict: neither vendor is "wrong" in a way that would make this a bug to
report against them. Both are non-conformant to the letter of RFC 6598 §4 in
exactly the same way, and the collision is inherent to the shared range.**

Reasoning, split by vendor:

**Tailscale — claims the full `100.64.0.0/10`.**
Tailscale states (tier B, its own docs) that it uses the range because it is
"reserved by RFC6598, *IANA-Reserved IPv4 Prefix for Shared Address Space*", and
acknowledges conflicts arise "if your internet service provider (ISP), or other
VPN, also uses the `100.64.0.0/10` subnet". Notably, Tailscale's public CGNAT
conflict page does **not** claim the full /10 in so many words; it says only
that each device gets "a unique 100.x.y.z IP address". The full-/10 claim in our
epic framing is consistent with observed routing behaviour but is not, in the
page reviewed, a documented vendor statement — flagged as a small gap.

Tailscale is not a Service Provider deploying CGN, so under §4 it is an "entity
using Shared Address Space for purposes other than for CGN service". Strictly,
§1's "can only be used in Service Provider networks" is not satisfied. However,
§1 also allows the space "can be used by multiple pieces of equipment", and
Tailscale's use is a widely-accepted industry practice precisely because the
range is the only sizeable non-RFC1918 space unlikely to collide with a user's
home LAN. This is a deliberate, documented, defensible engineering trade-off.

**NordVPN — places a resolver at `100.64.0.2`.**
`100.64.0.2` is the second usable address of the /10 — a conventional choice for
a CGN-side gateway/service address. Nord is likewise not a Service Provider
running CGN in the RFC's sense. Its use is no more and no less conformant than
Tailscale's.

**Adjudication.** There is no "first claim" or "reservation" mechanism in RFC
6598 — the range is explicitly *shared*, with no registry and no allocation
authority. Neither vendor can be said to be squatting on the other's space,
because **neither has, or can have, an exclusive claim.** Both are equally
outside §4's Service-Provider-only intent; both are behaving reasonably given
IPv4 exhaustion. **The collision is inherent to the shared range, and RFC 6598
§4 predicted that non-CGN users of it would "experience problems."**

Practical consequence: there is no standards-based argument to make to either
vendor. **The fix must be local to our host.** (Tier D inference, but a direct
one.)

---

## 3. macOS resolver priority: how `order` is assigned

### 3.1 What Apple's primary sources do and do not say

- `scutil(8)` (A1): does not mention `order` at all. **NOT DOCUMENTED.**
- `resolver(5)` (A1): documents `search_order` as "Only required for those
  clients that share a domain name with other clients. Queries will be sent to
  these clients in order by ascending `search_order` value." The example given
  is two competing clients for `.local`.

So the only A1 statement about ascending-order-wins is **scoped to clients
sharing a domain name**. Applying it to rank two unrelated default resolvers is
an extrapolation, not a documented rule.

### 3.2 What Apple's source code shows (tier A2 — the decisive evidence)

From `apple-oss-distributions/configd`, `dnsinfo/dnsinfo.h`:

```c
#define DEFAULT_SEARCH_ORDER    200000   /* search order for the "default" resolver domain name */
```

From `Plugins/IPMonitor/dns-configuration.c`, in
`add_supplemental_resolvers()` (line ~458):

```c
defaultOrder = DEFAULT_SEARCH_ORDER
             - (DEFAULT_SEARCH_ORDER / 2)
             + ((DEFAULT_SEARCH_ORDER / 1000) * (uint32_t)i);
if ((n_order > 0) &&
    !CFArrayContainsValue(service_order, CFRangeMake(0, n_order), keys[i])) {
        // push out services not specified in service order
        defaultOrder += (DEFAULT_SEARCH_ORDER / 1000) * n_services;
}
```

Substituting `DEFAULT_SEARCH_ORDER = 200000` gives the governing formula:

> **order = 100000 + (200 × i)**, where **`i` is the service's index in the
> system's network service order array.**

Two sibling functions produce the other bands seen in our snapshots:

- `add_private_resolvers()` (line ~596): `200000 - 50000 + 200i` = **150000 + 200i**
- `add_multicast_resolvers()` (line ~551): `200000 + 100000 + 200i` = **300000 + 200i**
  — this is the mDNS band, matching the `local` / `254.169.in-addr.arpa` /
  `*.ip6.arpa` entries at 300000, 300200, 300400 … in both our snapshots.

This decodes our measurements exactly. Every observed value is `100000 + 200i`
with an integer `i`:

| Resolver | Observed order | Implied service index `i` |
|---|---|---|
| MagicDNS `100.100.100.100` (`ts-on-nord-off`) | 101400 | 7 |
| MagicDNS domain-scoped `tailXXXX.ts.net.` | 101401 | 7 (+1 tiebreak) |
| MagicDNS (per epic framing) | 101600 | 8 |
| Nord `100.64.0.2` (`ts-off-nord-on`) | 104600 | 23 |
| Nord (per epic framing) | 104800 | 24 |
| LAN `192.0.2.1` default | 200000 | `DEFAULT_SEARCH_ORDER` exactly |
| mDNS `local` | 300000 | multicast band, i=0 |

The `101401` value is a domain-scoped entry sitting one unit above its parent
`101400`, consistent with the `search_order`-style tiebreak `resolver(5)`
describes for same-domain clients.

### 3.3 So *why* does Nord win?

**The `order` value is a derived artifact, not a cause.** It is computed *from*
the service's position `i` in the service order array. So the real question is
not "which order value wins" but "which network service is primary".

**Critical correction to the framing in the bead and ADR-001.** The premise
"lower order value appears to lose here" does not survive contact with the
evidence — and the error is deeper than a reversed inequality. Two things are
wrong with it:

1. Nord's number (104600/104800) is *higher* than MagicDNS's (101400/101600),
   which by the formula means Nord sits at a **larger service index** — i.e.
   **further down** the service order. Ascending-order-wins would predict
   **MagicDNS wins**, the opposite of the reported behaviour.
2. **The two numbers never compete with each other in the first place.** The
   Nord stanza that actually serves unscoped queries is not the supplemental
   one. In our own `ts-off-nord-on.txt` snapshot, Nord appears **twice**:
   resolver #1 at order 104600 carrying `flags: Supplemental`, and resolver #2
   at order **200000** with **no `domain` and no `Supplemental` flag**. It is
   resolver #2 — the domain-less one at exactly `DEFAULT_SEARCH_ORDER` — that is
   the default resolver. Comparing 104800 against 101600 compares two
   *supplemental* entries, neither of which is the winner.

The resolution is that ranking among *default* (unscoped) resolvers is not
decided by the `order` integer at all. Per `resolver(5)` (A1), `search_order`
applies only "**If multiple clients are available for the same domain name**" —
it is a tie-break *within* a domain-match set, with no authority over which
resolver becomes the default. The default resolver is instead chosen by a
**service election** that happens before `order` is ever consulted:

- `scutil(8)` (A1): "The **first listed** resolver(5) configuration is
  considered to be the 'default' configuration." Position in the list, not the
  order value, marks the default resolver.
- `configd/Plugins/IPMonitor/ip_plugin.c` (A2) states the election rule in its
  own header comment: the plugin "**decides which interface will be made the
  'primary' interface, that is, the one with the default route assigned**", and
  a dated change note records: "**don't elect a service to be primary if it
  doesn't have a default route**."
- `dns-configuration.c` (A2) reads `State:/Network/Global/IPv4` →
  `PrimaryService`, and passes that service's DNS entity as the
  `defaultResolver` to `add_default_resolver()`, which assigns it
  `DEFAULT_SEARCH_ORDER` (200000) when it carries no explicit search order —
  exactly the 200000 seen on Nord's resolver #2. Every other service's DNS is
  demoted to Supplemental or Scoped.

**Therefore: Nord wins because it owns the default route
(`default 10.5.0.2 UGScg utun11`, confirmed in our snapshot) and is thereby
elected the primary network service. Tailscale does not install a competing
default route in normal (non-exit-node) mode, which makes its service
structurally ineligible to become primary — no `order` value could change
that.** This is now supported by Apple source comments (A2) stating the
default-route rule outright, not merely inferred.

**`PrimaryRank` — the one mechanism that could override the above.** Apple's
SPI header `SCNetworkConfigurationPrivate.h` (A2, private) documents a priority
band combined with service order: "the service with the **smallest Rank value
(highest priority) becomes the 'primary' service**", with the relative order
`First, Default, Last, Never, Scoped`, and notes `kSCNetworkServicePrimaryRankFirst`
is "**Used by connection-oriented services like VPN**". In
`nwi/network_state_information_priv.h` the rank assertion occupies the **top 8
bits** and the service index the low 24, so a `First` assertion dominates
service order absolutely. Two caveats: `SCNetworkServiceSetPrimaryRank` is
**SPI, not public API**, and **whether NordVPN (or NEPacketTunnelProvider)
asserts `First` is NOT DOCUMENTED** — no public NetworkExtension property sets
PrimaryRank. This is a plausible additional reason Nord wins, but it is
unverified.

### 3.4 An important gap in our own evidence

**Neither committed snapshot captures both VPNs up at once.** Verified:
`snapshots/ts-off-nord-on.txt` contains zero occurrences of `100.100.100.100`;
`snapshots/ts-on-nord-off.txt` contains zero occurrences of `100.64.0.2`. The
head-to-head comparison asserted in ADR-001 (104800 vs 101600) is therefore
**not reproducible from any artifact in this repository** — the two numbers come
from different captures of mutually exclusive states, and the specific values
104800/101600 do not appear in either committed snapshot (which show 104600 and
101400/101600 respectively).

Because `order = 100000 + 200i` depends on the *service index*, and the service
list differs between the two states, **the order values are not directly
comparable across snapshots.** A both-VPNs-up capture is required before any
claim about relative ranking can be treated as measured. This should be recorded
against `dns-config-c15.6`.

---

## 4. Is resolver priority user-controllable? And would demoting Nord fix this?

### 4.1 The mechanism (tier A1)

Yes, network service order is user-controllable. From `man 8 networksetup`:

> `-ordernetworkservices service1 [service2] [service3] [...]`
> Use this command to designate the order network services are contacted on the
> specified hardware port. Name the network you want contacted first, then the
> second, and so on. Use "listnetworkserviceorder" to view current service order.
> Note: use quotes around service names which contain spaces.

Specific commands:

```sh
# inspect current order
networksetup -listnetworkserviceorder

# reorder (requires admin; names must match exactly, in full, in one call)
sudo networksetup -ordernetworkservices "Wi-Fi" "Tailscale" "NordVPN"
```

The GUI equivalent is System Settings → Network → (…) → **Set Service Order**.

Given §3.2, changing service order changes `i`, which changes the computed
`order` value. So the knob is real and it does move the numbers.

**But moving the numbers is not the same as changing the outcome.** Per §3.3,
the default resolver is selected by primary-service election — which requires
the service to own the **default route** — and that election happens *before*
`search_order` is consulted. Reordering services changes `i` and therefore the
supplemental `order` values, but it **cannot make a service without a default
route become primary**. Since Tailscale installs no competing default route,
`-ordernetworkservices` alone should not be able to hand MagicDNS the default
resolver slot. (The one theoretical exception is `PrimaryRank`, which is SPI and
not reachable from `networksetup`.)

### 4.2 Two serious caveats before treating this as a lever

1. **`utun` VPN interfaces frequently do not appear as orderable network
   services.** `-ordernetworkservices` operates on services in the Network
   preferences list. App-managed utun tunnels (Tailscale's `utun17`, and
   NordVPN's `utun11` when run through its own client rather than a system VPN
   profile) are often not present there, in which case there is nothing to
   reorder. The `dns-configuration.c` code anticipates exactly this: services
   **not** found in the service order array get pushed to the *back*
   (`defaultOrder += ... * n_services`). Whether these two services are
   orderable on this machine is **unverified** — it is answerable read-only with
   `networksetup -listnetworkserviceorder`, which I did not run (desk research).
2. **VPN clients re-assert their configuration on every connect.** ADR-001 Risk 1
   already documents that Nord auto-reconnects and rebuilds the resolver stack.
   Any manual ordering would have to survive that cycle.

### 4.3 Would demoting Nord below MagicDNS actually fix the problem?

**Verdict: NON-FIX. On the documented evidence it should not even work as
described, and if it did work it would trade our bug for a worse one. It should
not be adopted.**

The primary reason is now mechanical rather than merely consequential: per §4.1
above, **`-ordernetworkservices` cannot change which service is primary while
Nord holds the default route**, so it should not be able to demote Nord's
default resolver at all. Everything below is the secondary argument — why it
would still be the wrong thing to do even if the mechanism cooperated.

*If it worked as intended*, MagicDNS would become the primary resolver. Bare
`streamy` + search domain `tailXXXX.ts.net` → query goes to
`100.100.100.100` → resolves. So the *stated* symptom would clear.

But the consequences are bad, and they are the reason this is not a real fix:

- **It inverts the problem rather than solving it.** MagicDNS becomes the
  default resolver for **all** names, including every public domain. MagicDNS
  does forward non-tailnet queries upstream, so this may not break outright —
  but it routes all general DNS traffic through Tailscale's resolver path
  instead of Nord's. **For a privacy VPN user this is a significant and probably
  unwanted change**: DNS queries would no longer traverse the Nord tunnel, which
  partially defeats the point of running Nord. The brief's own framing — "Nord's
  resolver would still be consulted for non-tailnet names" — is actually the
  *reverse* of what happens; after demotion Nord's resolver would largely
  **stop** being consulted, which is worse, not better.
- **It does nothing about the underlying black hole.** The root problem is that
  `100.64.0.2` is inside the /10 Tailscale routes into the tailnet, so traffic
  to it is swallowed. Demoting it only means we *ask* it fewer questions. Any
  query that still lands on it — and DNS falls back across resolvers on timeout
  — still black-holes, still incurring the full resolver timeout. Ordering
  changes who is asked first; it does not repair a broken resolver.
- **It is fragile against reconnects.** Per §4.2(2) and ADR-001 Risk 1.
- **It is strictly worse than the chosen mechanism.** ADR-001's
  `/etc/resolver/tailXXXX.ts.net` is *surgical*: it redirects only
  `*.tailXXXX.ts.net` to MagicDNS and leaves all other traffic on Nord —
  preserving the privacy VPN's purpose. Service reordering is a *blunt*
  instrument that moves all DNS.

**Recommendation: do not add service reordering to the fix list as a candidate
remedy.** It has modest value as a *falsification probe* — the §3.3 model
predicts reordering will **not** dislodge Nord's default resolver, so if it did,
the model is wrong and worth revisiting. But that is a probe, not a fix.

The genuinely promising structural fix remains **ADR-001 Alternative (d)** —
Nord split-tunnelling `100.64.0.0/10`. §3.3 raises its standing considerably:
since primary election follows the default route, altering Nord's routing is the
only *documented* way to change which service is primary, and it simultaneously
addresses the black hole itself. The chosen ADR-001 mechanism
(`/etc/resolver/tailXXXX.ts.net`) remains correct and complementary — it
sidesteps the election entirely by using domain matching (§5) rather than trying
to win the default slot.

---

## 5. How do `/etc/resolver` files rank against interface-supplied resolvers?

This is ADR-001's central unverified assumption. **The documentation supports it,
with an important caveat.**

### 5.1 The documented rule (tier A1 — `resolver(5)`, SEARCH STRATEGY)

The man page on this machine describes a "Super" DNS client acting as a router
for queries:

> "A special meta-client, known as the 'Super' DNS client acts as a router for
> DNS queries. The Super client chooses among all available clients by finding a
> **best match** between the domain name given in a query and the names of all
> known clients."

> "The matching algorithm chooses the client with the **maximum number of
> matching domain components**. For example, if there are clients named 'a.b.c',
> and 'b.c', a search for 'x.a.b.c' would use the 'a.b.c' resolver
> configuration... **If there are no matches**, the configuration settings in the
> default client, generally corresponding to the /etc/resolv.conf file or to the
> 'primary' DNS configuration on the system are used for the query."

This is the key structural point: **domain specificity is a higher-precedence
dimension than default-resolver ranking.** The default/primary resolver is only
reached when there is **no** domain match. Nord's resolver is a *default*
resolver (no `domain` field — confirmed in our snapshot, resolver #2 at order
200000 has no domain). A query for `streamy.tailXXXX.ts.net` **does** match a
client named `tailXXXX.ts.net`. So the Super client should route it to
MagicDNS and never fall through to Nord's default.

Critically, `resolver(5)` also confirms the file-based and dynamic
configurations inhabit the *same* namespace with no privilege distinction:

> "The configuration for a particular client may be read from a file having the
> format described in this man page. These are at present located by the system
> in the /etc/resolv.conf file and in the files found in the /etc/resolver
> directory. However, client configurations are not limited to file storage...
> Users of the DNS system should make no assumptions about the source of the
> configuration data."

And on naming:

> "domain ... This option is normally not required by the macOS DNS search
> system when the resolver configuration is read from a file in the
> /etc/resolver directory. In that case **the file name is used as the domain
> name**."

So `/etc/resolver/tailXXXX.ts.net` correctly registers a client for that
domain without needing an explicit `domain` line. ADR-001's planned file content
(`nameserver 100.100.100.100`) is sufficient.

### 5.2 Answer to the headline question

**DOCUMENTED YES — a static `/etc/resolver` file should outrank a VPN-installed
*default* resolver for names inside its scoped domain, because domain matching
is evaluated before falling back to the default client.** Note the precise
scope of that claim: it holds because Nord's resolver is *domain-less*. It is
**not** a claim that `/etc/resolver` beats everything.

The A1 man-page reading is corroborated by Apple source (A2), which shows domain
specificity is not merely *first* but a strict cascade in which `order` is the
**last** tiebreaker. In `dns-configuration.c`, `compareDomain()` orders
candidates by: domain-less before domained → scoped → forward/reverse →
label-by-label from the TLD inward → more-labels before fewer — **and only then**
falls through to `compareBySearchOrder()`. Independently, mDNSResponder's
`BetterMatchForName()` hard-gates on suffix label count before any other
consideration. So a 3-label match on `tailXXXX.ts.net` is never weighed
against Nord's `order` value at all; the comparison never happens.

**This also disposes of the "match-everything" concern.** A VPN can register a
resolver with an empty match domain (`SupplementalMatchDomains: [""]`), which
sounds like it should capture every query. It does not defeat best-match.
`add_supplemental()` handles the empty case by *removing* the domain key
outright:

```c
if (CFStringGetLength(match_domain) > 0) {
    CFDictionarySetValue(match_resolver, kSCPropNetDNSDomainName, match_domain);
} else {
    CFDictionaryRemoveValue(match_resolver, kSCPropNetDNSDomainName);
}
```

So an empty match domain does **not** create a resolver scoped to `.` that
matches every name; it creates an *additional default* resolver. `scutil(8)`
(A1) corroborates: supplemental configurations without a domain "will be used as
a 'default' configuration in addition to the first listed." A zero-label matcher
can never out-specify a 3-label suffix, so it wins only among default-tier
resolvers.

This is exactly the shape of Nord's resolver #1 in our snapshot: `Supplemental`
flag, **no `domain:` line**. Its supplemental `order` therefore only ranks it
against other defaults — it cannot pull `*.tailXXXX.ts.net` away from a
domain-scoped entry.

Note also the strong corroboration already in ADR-001: Tailscale itself installs
a domain-scoped resolver of exactly this shape (`domain : tailXXXX.ts.net.` →
`100.100.100.100`, order 101401), and it works when Nord is down. The *shape* is
proven; what is unproven is its behaviour against a Nord-up state.

### 5.3 The caveat: same-domain competition

`resolver(5)` says `search_order` is "Only required for those clients that share
a domain name with other clients", and that `domain` "must be provided when
there are multiple resolver clients for the same domain name, since multiple
files may not exist having the same name."

When Tailscale is running it *already* registers a dynamic client for
`tailXXXX.ts.net`. Adding a static file for the same domain creates **two
clients for one domain** — the documented tie-break case. Both point at
`100.100.100.100`, so the outcome is benign either way.

On the sub-question of what `search_order` a static file receives: this is **not
documented in any A1 source**, but A2 source evidence answers it.
`dnsinfo/dnsinfo_flatfile.c` sets `search_order` only in its `TOKEN_SEARCH_ORDER`
branch, over a `calloc`'d struct — so a file with no `search_order` line gets
**0**, not 200000. (200000 is `DEFAULT_SEARCH_ORDER`, which applies to the system
*default* resolver, not to flat files — a common community misreading.) Since
sorting is ascending and lower wins, **0 means the static file also wins its
same-domain tie-break against Tailscale's dynamic entry at 101401.** Low risk
either way here, since both target the same nameserver.

**Optional hardening for `c15.4`:** adding an explicit `search_order 1` line to
`/etc/resolver/tailXXXX.ts.net` makes the tie-break deterministic rather than
relying on the undocumented default. Harmless if the tie never arises. Flagged
as a suggestion, not a requirement — ADR-001 currently specifies the file
contains exactly `nameserver 100.100.100.100`, so changing it is the operator's
call, not an autonomous edit.

### 5.4 How this must be tested (matters for `c15.6`)

**Do not verify this with `dig` or `nslookup`.** Both bypass the macOS
multi-client resolver entirely and talk straight to a nameserver, so they cannot
observe `/etc/resolver` routing. This is confirmed by Apple DTS (tier A3) —
Quinn "The Eskimo!" on the Apple Developer Forums:

> "dig is a DNS debugging tool and thus having it go through the system resolver
> would be counter productive."

and, on the general principle:

> "Apple's position on this is that all apps should use the system DNS resolver."

Apple's own generated `/etc/resolv.conf` header states the file "is not
consulted for DNS hostname resolution" — yet `dig` reads exactly that file. A
test using `dig` would therefore produce a **false negative** and could wrongly
condemn a working fix. **This is the single most likely way `c15.6` could reach
a wrong conclusion.** The correct tools route through libinfo → mDNSResponder:

```sh
dns-sd -G v4 streamy.tailXXXX.ts.net                  # best: literally DNSServiceGetAddrInfo
dscacheutil -q host -a name streamy.tailXXXX.ts.net   # system resolver
ping -c1 streamy.tailXXXX.ts.net                      # getaddrinfo
scutil --dns | grep -A6 tailXXXX                      # registration only, NOT resolution
```

Two cautions: `scutil --dns` proves the client is *registered*, not that queries
are *routed* to it — those are different claims, and only the first three
commands test the second. And `scutil --dns-query` **does not exist**; do not
put it in the verification script.

Note also that `dig @100.100.100.100 streamy.tailXXXX.ts.net` proves only that
MagicDNS *answers*; it says nothing about which resolver the system would have
chosen. To observe routing directly — the actual claim under test — watch the
wire:

```sh
sudo tcpdump -i any -n port 53      # confirm the query leaves toward 100.100.100.100
```

Linkage confirms the split: `dig` carries its own BIND resolver and reads
`/etc/resolv.conf`, while `dscacheutil` links OpenDirectory and takes the libinfo
path. Browsers with their own DoH stacks (Firefox, Chrome) also bypass
`/etc/resolver` and are not valid test clients.

**Still honoured on macOS 26?** Yes. `/usr/libexec/configd` on a 26.5 system
still contains the strings `/etc/resolver`, `/etc/resolver changed`, and
`add_default_resolver`, and `man 5 resolver` ships current and undeprecated.
configd watches the directory live (that is what the `/etc/resolver changed`
string is), so files are re-read on change and on network reconfiguration; the
file need not pre-exist the VPN connection, and `killall -HUP mDNSResponder` is
not required (though harmless). *NOT DOCUMENTED:* any guarantee of re-read
latency. Note also a known macOS 26 bug affecting `/etc/resolver` for
**non-IANA-root TLDs** (`.internal`, `.test`, `.lan`) — `ts.net` is a real TLD,
so it does not apply to us.

### 5.5 Residual risk

`resolver(5)`'s SEARCH STRATEGY text long predates modern VPN behaviour (the
page is dated 2022 even on macOS 26.5). The broad-match-domain concern is
addressed in §5.2 above and does not defeat best-match.

The one risk that **would** defeat everything in this section: if NordVPN's
Shield component (or any system/network extension) performs transparent DNS
proxying or content filtering at the NECP/NetworkExtension layer, it intercepts
*below* resolver selection entirely. No `/etc/resolver` configuration can
override that, because the query never reaches resolver selection in the
intended form. This is **inference, not documented** — but it is testable: the
`dns-sd -G v4` probe above would reveal it.

**Documented ≠ measured; ADR-001 Risk 1 stands unchanged.** Everything in §5 is
a documentation-and-source-based prediction. The mechanism is well-evidenced,
but it has not been observed working against a live Nord-up state on this
machine.

---

## 6. Summary of verdicts

| # | Question | Answer | Confidence |
|---|---|---|---|
| 1 | Does RFC 6598 anticipate this collision? | Yes for overlap (§4 "identical Shared Address Space ranges... on two different interfaces") and yes for non-CGN users hitting "problems" (§4). No for resolver selection specifically. | High (Standards Track text) |
| 2 | Is either vendor wrong? | **Neither.** Both use the range outside its Service-Provider-only intent (§1, §4) in identical fashion; the range has no allocation authority and no exclusivity. Collision is inherent. No standards argument available; fix must be local. | High |
| 3 | How is `order` assigned? | `order = 100000 + 200i` for supplemental resolvers (`i` = service order index), from `dns-configuration.c`; `DEFAULT_SEARCH_ORDER = 200000` from `dnsinfo.h`. Undocumented in `scutil(8)`. | High for formula (A2); **the "lower loses" premise is refuted** |
| 3b | Why does Nord win? | Because it owns the **default route** and is thereby elected **primary network service** (`ip_plugin.c`: "don't elect a service to be primary if it doesn't have a default route"). Nord's *winning* stanza is the domain-less one at order **200000**, not the 104600 supplemental — the two cited numbers never compete. Tailscale installs no competing default route, so it is structurally ineligible. | High (A2 source comments state the rule) |
| 4 | Is priority user-controllable? | Yes: `sudo networksetup -ordernetworkservices ...` (A1). But utun VPN services often are not listed, and VPN reconnects re-assert config. | High for command; medium for applicability |
| 4b | Would demoting Nord fix it? | **NON-FIX.** It should not even work — service order cannot override primary election while Nord owns the default route — and if it did, it would route *all* DNS through MagicDNS, defeating the privacy VPN's purpose without repairing the black hole. | High |
| 5 | Does `/etc/resolver` outrank a VPN default resolver? | **DOCUMENTED YES** for its scoped domain. Domain specificity is a strict cascade in which `order` is the *last* tiebreaker (`compareDomain()`, `BetterMatchForName()`), and Nord's resolver is domain-less (zero labels), so the comparison never happens. A static file also wins the same-domain tie-break (default `search_order` = 0). | High as documentation; **still unmeasured** |

## 7. Open items to carry forward

1. **Capture a both-VPNs-up snapshot.** No committed artifact has both. Until
   then the 104800-vs-101600 comparison in ADR-001 is unsubstantiated. → `c15.6`
2. **Correct ADR-001's causal claim.** It states "a lower order value wins in
   macOS's `scutil` resolver selection" and infers Nord wins because
   `104800 > 101600`. Per §3.3 this is wrong twice over: the higher value means
   Nord is *further down* the service order, and — more fundamentally — those
   two supplemental stanzas never compete, because Nord's actual default
   resolver is the domain-less entry at order 200000. The real driver is
   primary-service election, which requires owning the **default route**. The
   ADR's *decision* is unaffected — a domain-scoped resolver is the right
   mechanism either way, and §5 strengthens the case for it — but the rationale
   should be amended. This also raises the standing of ADR-001 Alternative (d)
   (Nord split-tunnelling `100.64.0.0/10`): removing Nord's default route is the
   only documented way to change the election outcome.
3. **Verification must not use `dig`/`nslookup`/`host`.** They bypass the system
   resolver and would yield a false negative on a working fix. Record in the
   verification script that `dns-sd -G v4`, `dscacheutil -q host -a name`, and
   `ping` are the valid probes, and that `scutil --dns-query` does not exist.
   → `c15.5`
4. **Read-only check worth running:** `networksetup -listnetworkserviceorder`,
   to establish whether Nord/Tailscale are orderable services at all.
5. **Untestable by documentation:** whether NordVPN's Shield performs
   transparent DNS interception at the NECP layer, which would bypass
   `/etc/resolver` entirely (§5.5). The `dns-sd` probe would reveal it. → `c15.6`

## 8. Sources

**Tier A1 — Apple primary (local man pages, macOS 26.5):** `man 5 resolver`;
`man 8 scutil`; `man 8 networksetup`.

**Tier A2 — Apple open source:**
- [`configd/dnsinfo/dnsinfo.h`](https://github.com/apple-oss-distributions/configd/blob/main/dnsinfo/dnsinfo.h) — `DEFAULT_SEARCH_ORDER`, resolver flags
- [`configd/Plugins/IPMonitor/dns-configuration.c`](https://github.com/apple-oss-distributions/configd/blob/main/Plugins/IPMonitor/dns-configuration.c) — `add_supplemental_resolvers()`, `add_private_resolvers()`, `add_multicast_resolvers()`, `add_default_resolver()`, `compareBySearchOrder()`
- [`configd/Plugins/IPMonitor/ip_plugin.c`](https://github.com/apple-oss-distributions/configd/blob/main/Plugins/IPMonitor/ip_plugin.c) — primary-interface election; "don't elect a service to be primary if it doesn't have a default route"
- [`configd/SystemConfiguration.fproj/SCNetworkConfigurationPrivate.h`](https://github.com/apple-oss-distributions/configd/blob/main/SystemConfiguration.fproj/SCNetworkConfigurationPrivate.h) — `PrimaryRank` bands (SPI, not public API)
- [`configd/nwi/network_state_information_priv.h`](https://github.com/apple-oss-distributions/configd/blob/main/nwi/network_state_information_priv.h) — `Rank` bit-packing: assertion in top 8 bits, service index in low 24

**Version caveat for all A2 citations:** the code read is `main` on
`apple-oss-distributions/configd`. Apple publishes no tag pinned to macOS 26.5,
so applicability to Darwin 25.5.0 is established by *behavioural match* — every
`order` value in our snapshots is reproduced exactly by the formulas — not by a
version-pinned source reference.

Also consulted (A2): `configd/dnsinfo/dnsinfo_flatfile.c` (`/etc/resolver` file
parsing; default `search_order` = 0), `dns-configuration.c` `compareDomain()` /
`add_supplemental()`, and mDNSResponder `mDNSCore/mDNS.c` `BetterMatchForName()`
/ `GetBestServer()`. Caveat: the mDNSResponder platform glue
(`ConfigDNSServers`, `compare_dns_configs`) is absent from the current public
repo and was read from an older mirror — treat that layer as verified-as-of-mirror.

**Tier A3 — Apple staff:** [Apple Developer Forums thread 127735](https://developer.apple.com/forums/thread/127735) and [thread 742655](https://developer.apple.com/forums/thread/742655) (Quinn "The Eskimo!", Apple DTS) — `dig` uses its own internal resolver whereas `DNSServiceGetAddrInfo` uses the system resolver; apps should use the system resolver; the classic `resolv.conf` infrastructure is "a compatibility measure, not the source of truth". Also Apple's generated `/etc/resolv.conf` header: the file "is not consulted for DNS hostname resolution."

**Standards:** [RFC 6598](https://www.rfc-editor.org/rfc/rfc6598.txt) (BCP 153), §§1, 4, 6, 7.

**Tier B — vendor:** [Tailscale, "Troubleshoot CGNAT conflicts"](https://tailscale.com/docs/reference/troubleshooting/network-configuration/cgnat-conflicts); [Tailscale, "Can I use Tailscale alongside other VPNs?"](https://tailscale.com/docs/reference/faq/other-vpns).

**Tier C — community (corroborating only):** [rakhesh.com, "VPN client over-riding DNS on macOS"](https://rakhesh.com/powershell/vpn-client-over-riding-dns-on-macos/); [invisiblethreat.ca, "Per-domain resolvers in macOS" (2025)](https://invisiblethreat.ca/technology/2025/04/12/macos-resolvers/); [vninja.net, "macOS: Using Custom DNS Resolvers"](https://vninja.net/2020/02/06/macos-custom-dns-resolvers/); [tailscale/tailscale#14746](https://github.com/tailscale/tailscale/issues/14746).

**Local artifacts:** `snapshots/ts-off-nord-on.txt`, `snapshots/ts-on-nord-off.txt`, `docs/adr-001-hostname-resolution.md`.

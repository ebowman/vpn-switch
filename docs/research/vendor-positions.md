# Vendor Positions: Tailscale and NordVPN on the CGNAT DNS Address Collision

Research output for bead `dns-config-seo.1`. Input: the confirmed root cause in `dns-config-lsy`.

**Research date:** 2026-08-15/16
**Applicability:** Tailscale current as of 2026-08; NordVPN macOS app (direct-download and App Store variants both considered); macOS Darwin 25.5.0.

## Problem under investigation

NordVPN's macOS app installs `100.64.0.2` as a DNS resolver. That address falls inside `100.64.0.0/10`, the RFC 6598 CGNAT range Tailscale claims and routes via its `utun` interface. With both running, `route -n get 100.64.0.2` resolves to Tailscale's interface, so queries to Nord's own nameserver are routed into the tailnet and black-holed. Nord installs its resolver at a higher scutil priority than MagicDNS (order 104800 vs 101600), so all DNS fails.

## Source labelling convention

- **OFFICIAL VENDOR DOCUMENTATION** — published by the vendor on its own docs/support property, presented as vendor guidance.
- **COMMUNITY CONTENT** — user-authored, including posts on a vendor-hosted forum or a vendor's GitHub issue tracker where the text is not a maintainer statement. A post on a vendor forum is *not* a vendor position.

A note on dates: Tailscale's docs pages carry visible "Last validated" dates. NordVPN's support articles (Zendesk-hosted) do **not** display publication or last-updated dates on the rendered page; this is noted per-answer as a sourcing weakness that cannot be resolved from the public page.

---

# TAILSCALE

## (a) Does Tailscale document its 100.64.0.0/10 claim and known conflicts with other software using CGNAT space?

**Answer: YES — the claim and the conflict class are both documented. Conflicts are documented generically, not as a catalogue of specific known-conflicting software.**

Tailscale documents that it uses the CGNAT range for device addressing:

- **Reserved IP addresses** — describes `100.64.0.0/10` as "The CGNAT range Tailscale uses for device IP addresses," spanning `100.64.0.0` through `100.127.255.255`. Also documents `100.100.100.100` (Quad100/MagicDNS, a device-local service address whose traffic "stays on the local device and doesn't traverse your tailnet") and `100.115.92.0/23` (reserved for Tailscale internal use).
  - URL: https://tailscale.com/docs/reference/reserved-ip-addresses
  - Date: Last validated **Jan 12, 2026**
  - **OFFICIAL VENDOR DOCUMENTATION**
  - *Caveat relevant to our root cause:* this page describes the /10 as the range Tailscale **assigns device addresses from**. It does not explicitly state that the client **routes the entire /10**. Our measured behaviour (a route for an address Tailscale never assigned to any node) is therefore not directly asserted by this page.

- **Troubleshoot CGNAT conflicts** — a dedicated troubleshooting page for exactly this conflict class, acknowledging conflicts within the "100.64.0.0/10 subnet (from 100.64.0.0 to 100.127.255.255)."
  - URL: https://tailscale.com/docs/reference/troubleshooting/network-configuration/cgnat-conflicts
  - Date: Last updated **Mar 16, 2026**
  - **OFFICIAL VENDOR DOCUMENTATION**

- **Can I use Tailscale alongside other VPNs?** — states "in most cases, you can't use Tailscale alongside other VPNs without a workaround," and specifically: "If the other VPN uses IP addresses from the Carrier-Grade NAT (CGNAT) range (`100.64.0.0` through `100.127.255.255`) that Tailscale uses, they will conflict."
  - URL: https://tailscale.com/kb/1105/other-vpns
  - Date: Last updated **January 12, 2026**
  - **OFFICIAL VENDOR DOCUMENTATION**

Additionally, the interop problem is tracked as a long-standing open upstream issue:

- **Issue #1381, "Better interop with other users of 100.64.0.0/10"** — opened by @danderson (Tailscale) on **2021-02-22**, **still open** as of this research. Describes conflicts when the underlay network also uses the range, including anti-spoofing rules on Linux and routing errors on Windows/Mac/iOS. A related PR (#18781) is referenced.
  - URL: https://github.com/tailscale/tailscale/issues/1381
  - **COMMUNITY CONTENT / issue tracker.** The issue was filed by a Tailscale founder, which makes it credible evidence that Tailscale *acknowledges* the problem, but an open issue is not a shipped vendor position or a documented remedy.

**Bottom line for (a):** Tailscale documents the claim and documents the conflict class explicitly. It does not publish a list of specific third-party software known to collide, and the "we route the whole /10" behaviour our test measured is implied by the troubleshooting guidance rather than stated outright.

## (b) Is there an official way to narrow or override the claimed range?

**Answer: PARTIALLY — there is a documented way to narrow which addresses are ASSIGNED, but NOT a documented way to narrow what the client CLAIMS/ROUTES. The only documented remedy for a genuine CGNAT collision is to disable IPv4 entirely.**

Two documented mechanisms, neither of which does what we need:

1. **IP pool** — a tailnet policy file node attribute that restricts assignment to a subset of `100.64.0.0/10`. Must remain within the CGNAT range; `100.100.0.0/24`, `100.100.100.0/24`, and `100.115.92.0/23` are permanently reserved and unavailable. No minimum size and no licensing-tier restriction is documented.
   - URL: https://tailscale.com/kb/1304/ip-pool
   - Date: Last validated **Jan 12, 2026**
   - **OFFICIAL VENDOR DOCUMENTATION**
   - **Critical limitation:** the page addresses **which addresses get assigned to nodes**, and does not document any change to client routing behaviour. Narrowing the pool is therefore **not documented to stop the client from claiming/routing the rest of the /10**, which is the behaviour that black-holes `100.64.0.2`. Treat "narrow the pool to fix the route" as an untested hypothesis, not a documented remedy.

2. **Disable IPv4** — the CGNAT-conflicts page's actual recommended remedy: disable IPv4 tailnet-wide or selectively via the `disable-ipv4` node attribute, making Tailscale IPv6-only. The page warns that "disabling IPv4 will prevent you from accessing IPv4-only resources on your network."
   - URL: https://tailscale.com/docs/reference/troubleshooting/network-configuration/cgnat-conflicts
   - Date: **Mar 16, 2026**
   - **OFFICIAL VENDOR DOCUMENTATION**

**On the specific flags named in the bead:** `--netfilter-mode` and `--accept-routes` do **NOT** appear as CGNAT-conflict remedies on either the CGNAT-conflicts page or the other-VPNs page — **NOT DOCUMENTED** as a fix for this problem. (`--netfilter-mode` is Linux/iptables-scoped and is not applicable to macOS in any case.)

Other workarounds Tailscale documents on the other-VPNs page — **userspace networking mode** (Tailscale runs as a SOCKS5 proxy rather than creating a network interface) and **split tunnels** (the page notes some VPN providers support split-tunnel DNS, and cautions this does not work with exit nodes) — are aimed at the general co-existence problem rather than at narrowing the claimed range.
- URL: https://tailscale.com/kb/1105/other-vpns — **OFFICIAL VENDOR DOCUMENTATION**, Jan 12 2026.

**Bottom line for (b):** No documented knob narrows what the Tailscale client routes on macOS. Documented options are IPv6-only, userspace mode, or a route exception on the *other* VPN's side.

## (c) Do they name NordVPN or "other VPN" conflicts specifically?

**Answer: "Other VPN" conflicts — YES, generically and explicitly. NordVPN by name — NOT DOCUMENTED.**

Neither https://tailscale.com/kb/1105/other-vpns (Jan 12 2026) nor https://tailscale.com/docs/reference/troubleshooting/network-configuration/cgnat-conflicts (Mar 16 2026) names NordVPN or any other specific consumer VPN vendor as a known conflict. Both refer generically to "other VPNs" / "the other VPN." Issue #1381 does not name NordVPN either. The only vendor named on the other-VPNs page is Mullvad, and that is as a *feature* (Mullvad exit nodes, beta), not as a conflict.

Both are **OFFICIAL VENDOR DOCUMENTATION**. The absence of NordVPN by name is a documented-absence finding, verified across the two relevant pages plus the upstream issue.

---

# NORDVPN

## (d) Does NordVPN document its DNS server addresses? Is 100.64.0.2 the documented one?

**Answer: YES, NordVPN documents its DNS addresses — they are `103.86.96.100` and `103.86.99.100`. `100.64.0.2` is NOT documented anywhere. It is undocumented behaviour.**

- **What are NordVPN DNS server addresses?** — lists exactly two addresses: `103.86.96.100` and `103.86.99.100`. `100.64.0.2` does not appear.
  - URL: https://support.nordvpn.com/hc/en-us/articles/19587726859793-What-are-NordVPN-DNS-server-addresses
  - Date: **no publication or last-updated date is displayed on the page** — sourcing weakness.
  - **OFFICIAL VENDOR DOCUMENTATION**

- **How to change your DNS using the NordVPN app** — likewise instructs users to enter `103.86.96.100` and `103.86.99.100`. Notes that "Adding NordVPN DNS servers via the application ensures that they are being used while connected and can decrease the chances of any third-party application interfering." `100.64.0.2` does not appear.
  - URL: https://support.nordvpn.com/hc/en-us/articles/35512783419281-How-to-change-your-DNS-using-the-NordVPN-app
  - Date: **not displayed** — sourcing weakness.
  - **OFFICIAL VENDOR DOCUMENTATION**

Targeted searches for `100.64.0.2` in connection with NordVPN — including against NordVPN's own domains and in the context of Threat Protection / DNS filtering — returned **no NordVPN documentation mentioning the address at all**.

**Finding: `100.64.0.2` is NOT DOCUMENTED by NordVPN.** Our observed resolver address is undocumented internal behaviour — most plausibly a local/in-tunnel interception resolver used for DNS filtering, but *that attribution is inference, not a vendor position, and is explicitly not claimed here as fact.* The operational consequence is important: because the address is undocumented, there is no vendor commitment to it and no vendor guidance covering its collision with CGNAT users.

## (e) Does the NordVPN macOS app support setting a CUSTOM DNS SERVER? [MOST DECISION-RELEVANT]

**Answer: YES. NordVPN officially documents an in-app custom DNS setting on macOS, in the app's own Settings, with a documented prerequisite: DNS filtering must be disabled first.**

Two independent official support articles confirm this.

**Source 1 — the cross-platform article.** "How to change your DNS using the NordVPN app" explicitly lists **Windows, macOS, iOS, and Android**, with macOS covered in its own dedicated section. Documented caveats: on **macOS you must disable DNS filtering** before configuring custom DNS (on iOS/Android, Threat Protection must be disabled). No limit on the number of custom DNS addresses is stated.
- URL: https://support.nordvpn.com/hc/en-us/articles/35512783419281-How-to-change-your-DNS-using-the-NordVPN-app
- Date: **not displayed** — sourcing weakness.
- **OFFICIAL VENDOR DOCUMENTATION**

**Source 2 — the macOS-specific article**, which gives the exact in-app click path:
1. Click the **shield icon**
2. Make sure that **DNS filtering** is disabled
3. Go to **settings**
4. Open the **DNS** tab
5. Press **add new DNS** and input the addresses
6. Turn the feature on, and **reconnect to the VPN**

- URL: https://support.nordvpn.com/hc/en-us/articles/19921173364113-How-to-change-your-DNS-servers-on-macOS
- Date: **not displayed** — sourcing weakness.
- **OFFICIAL VENDOR DOCUMENTATION**

**Corroboration/contradiction guidance for the human checking the UI:**

- The documented path is **shield icon → verify DNS filtering is OFF → Settings → DNS tab → "add new DNS"**. If the DNS tab is missing or the toggle is greyed out, the most likely explanation is that **DNS filtering / Threat Protection is still enabled** — the docs make disabling it a prerequisite, and this is the single most common reason the control appears absent.
- **App-variant caveat, weakly sourced:** neither official article distinguishes the **direct-download** build from the **Mac App Store** build. Community/third-party sources claim the website version offers custom DNS while the App Store version is a simpler sandboxed build — this is **COMMUNITY CONTENT, NOT a vendor position**, and NordVPN does **not** document any such difference. If the DNS tab is genuinely absent with filtering disabled, the App Store build is the leading suspect, but that is a hypothesis to test, not documented fact. NordVPN does maintain a separate App Store setup article (https://support.nordvpn.com/hc/en-us/articles/20492395403921-Setting-up-NordVPN-App-Store-version-on-macOS), confirming the two builds are distinct products.

**Decision relevance:** if the custom DNS field exists and accepts arbitrary addresses, setting it to `103.86.96.100` / `103.86.99.100` should replace `100.64.0.2` with routable addresses outside `100.64.0.0/10`, resolving the collision without touching Tailscale. This is the most promising documented remedy found in this research. Note the documented trade-off: **DNS filtering must be off**, so Threat Protection's DNS-level blocking is lost.

## (f) Does NordVPN document split-tunnelling on macOS, and is it APP-level or ROUTE-level?

**Answer: macOS is NOT a supported split-tunnelling platform. Where the feature does exist it is APP-level, not route-level — so it would not help exclude 100.64.0.0/10 even if it were available.**

- **What is Split Tunneling and how to use it with NordVPN?** — covers Windows 7/8.1, Windows 10/11, Android, and Android TV. **macOS is not listed.** On Windows and Android the feature works by **selecting applications** ("Select the apps you wish not to be affected by the VPN connection"). Only **Linux** is documented as using a different mechanism — an "Allowlist" that operates on **ports, port ranges, or subnets**.
  - URL: https://support.nordvpn.com/hc/en-us/articles/19618692366865-What-is-Split-Tunneling-and-how-to-use-it-with-NordVPN
  - Date: **not displayed** — sourcing weakness.
  - **OFFICIAL VENDOR DOCUMENTATION**
  - Precision note: on this page macOS is *absent from the supported list* rather than *explicitly excluded*. The exclusion is inferred from the enumeration.

- NordVPN also documents a browser-extension-only "Exclude from VPN" website split-tunnelling feature, which is scoped to the browser and irrelevant to system DNS.
  - URL: https://support.nordvpn.com/hc/en-us/articles/20321703651985-Split-Tunneling-feature-on-NordVPN-extension
  - **OFFICIAL VENDOR DOCUMENTATION**

**Conclusion for (f):** Route-level exclusion of `100.64.0.0/10` via NordVPN's macOS app is **not available**. Two independent reasons: macOS is not a supported split-tunnelling platform, and the feature is app-selection-based rather than route-based everywhere except Linux (whose subnet Allowlist is the one variant that *would* have been useful). Note that Tailscale's own other-VPNs guidance recommends exactly the remedy NordVPN cannot provide on macOS — a route exception for `100.64.0.0/10` in the other VPN's client.

*A widely-repeated third-party explanation attributes the macOS gap to Apple's Network Extension framework replacing lower-level networking access from macOS Big Sur onward. This is **COMMUNITY CONTENT** and is not confirmed by NordVPN documentation; recorded as context only.*

---

# Summary table

| # | Question | Answer | Strength |
|---|---|---|---|
| a | Tailscale documents /10 claim + CGNAT conflicts? | YES — claim + dedicated conflicts page; generic, no software catalogue | Strong |
| b | Official way to narrow/override claimed range? | PARTIAL — IP pool narrows *assignment* only; documented remedy is disable-IPv4. `--netfilter-mode`/`--accept-routes` NOT DOCUMENTED as fixes | Strong |
| c | NordVPN named specifically? | NOT DOCUMENTED — "other VPN" generic only | Strong |
| d | Nord DNS addresses documented? Is 100.64.0.2 it? | YES: `103.86.96.100` / `103.86.99.100`. `100.64.0.2` NOT DOCUMENTED | Strong on the documented pair; undocumented-address finding is a verified absence |
| e | macOS app custom DNS? | **YES** — Settings → DNS tab → "add new DNS"; requires DNS filtering OFF | Strong (two official articles); app-variant caveat weak |
| f | macOS split tunnelling, app- or route-level? | macOS NOT supported; APP-level elsewhere (Linux-only subnet allowlist). Cannot exclude `100.64.0.0/10` | Strong |

# Weakly-sourced answers — flagged

1. **All NordVPN support articles lack visible dates.** Every NordVPN citation in (d), (e), and (f) is undated on the rendered Zendesk page. Content currency versus the installed macOS app build cannot be verified from the public pages. This affects (d), (e), and (f) equally.
2. **(e) app-variant distinction (direct-download vs Mac App Store)** is **community-sourced only** and contradicted by nothing but also confirmed by nothing official. Do not treat as a vendor position.
3. **(f) macOS exclusion is inferred from an enumeration**, not from an explicit "macOS is not supported" statement in the primary article.
4. **(b) IP-pool-as-routing-fix is explicitly NOT established.** The IP pool doc covers assignment; whether narrowing it changes client routing is untested and undocumented. Do not carry this forward as a documented remedy.
5. **(a) "Tailscale routes the entire /10"** — our measured behaviour — is consistent with but not explicitly asserted by the reserved-IP-addresses page, which frames the /10 as the assignment range.
6. **The origin/purpose of `100.64.0.2`** is undocumented. Any explanation (local filtering resolver, Meshnet-adjacent addressing) is inference and is not presented here as vendor position.

# Implications for the recommendation (bead dns-config-seo.4)

- **Most promising documented remedy: NordVPN in-app custom DNS (e).** It is officially documented on macOS, moves the resolver out of `100.64.0.0/10` entirely, and requires no Tailscale change. Cost: DNS filtering must be disabled.
- **Tailscale-side narrowing is a dead end as documented (b).** The only official CGNAT-conflict remedy is IPv6-only, which is disproportionate and breaks IPv4-only resources.
- **NordVPN route-level exclusion is unavailable on macOS (f)** — so Tailscale's own recommended workaround (route exception in the other VPN) cannot be applied here.
- **Neither vendor acknowledges the other (c),** and Nord's colliding address is undocumented (d), so there is no vendor-supported path and no vendor commitment to the current behaviour on either side.

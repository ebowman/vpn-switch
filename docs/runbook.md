# Runbook: NordVPN + Tailscale + VPN Switch on macOS

This is the full operational runbook. The short overview is the repository [README](../README.md).

VPN Switch's runbook for this Mac: what runs, how to set up a fresh machine,
daily use, verification, troubleshooting, tradeoffs, and uninstall. This
document assumes the **final** setup — Tailscale standalone + NordVPN over a
native IKEv2 profile + the VPN Switch menu bar app. For the full narrative of
how that setup was arrived at (what broke, what was tried, what was
measured), see [`docs/findings.md`](findings.md); for the decision
record, see [`docs/adr-002-nordvpn-ikev2.md`](adr-002-nordvpn-ikev2.md).
This runbook does not repeat either — it links them.

## 0. The 30-second version (read this first)

**How do I turn NordVPN on or off now?** Not with the NordVPN app — that is
the one thing that must stay disconnected (its tunnel collides with
Tailscale). Use either:

- **VPN Switch** (menu bar) → click **NordVPN**. *Requires the two Shortcuts
  (Section 3(c)); if they do not exist yet, the toggle shows a message
  telling you so.*
- **System Settings → VPN → NordVPN IKEv2 → toggle.**

**How do I turn Tailscale on or off?** VPN Switch → **Tailscale**, or the
Tailscale menu bar app. Both are fine.

**Both on at once is the normal state.** Bare `streamy` / `mac-mini`
resolve in every combination: tailnet IPs while Tailscale is up, LAN IPs
while it is off (at home).

**One-time step that makes VPN Switch drive NordVPN:** open **Shortcuts.app**
→ **+** → add the **Set VPN** action → VPN: **NordVPN IKEv2** → **Connect** →
name it exactly `NordVPN On`. Repeat with **Disconnect** → `NordVPN Off`.
(Not "Toggle".) That is the only handle macOS offers for a profile-installed
VPN; everything else in this repo already works without it.

## 1. What this repo is

Bare hostnames (`streamy`, `mac-mini`) sometimes failed to resolve, and
at least once the whole network died, whenever NordVPN and Tailscale were
both active on this Mac — behavior that depended on which VPN was up and in
what order. The root cause: the NordVPN **app**'s tunnel installs a DNS
resolver at `100.64.0.2`, inside the `100.64.0.0/10` CGNAT range that
Tailscale claims and routes entirely for its own tailnet addressing — the two
collide, and the collision black-holes DNS and, separately, tailnet routing.
The fix is not a DNS trick: **run NordVPN over a native IKEv2 configuration
profile instead of the app**. Nord's IKEv2 servers push a resolver
(`103.86.96.100`/`103.86.99.100`) and tunnel address (`10.6.x`) entirely
outside CGNAT space, so there is nothing for Tailscale's route to capture,
and the two coexist cleanly. The **VPN Switch** menu bar app and
`bin/vpn-ctl.sh` give independent on/off control of both, with status derived
from reality (interfaces, resolvers, a real HTTPS fetch), never from a status
API alone. Full story: [`docs/findings.md`](findings.md). Decision:
[`docs/adr-002-nordvpn-ikev2.md`](adr-002-nordvpn-ikev2.md).

## 2. What runs on the Mac

| Component | What it is | Why |
|---|---|---|
| Tailscale | **Standalone build** (not the Mac App Store build) | Sandboxed MAS build has no `tailscale` CLI on PATH and withholds most config surface; the standalone build is needed for the real CLI (`dns-config-p6t`). |
| NordVPN | **Native IKEv2 configuration profile** — NOT the NordVPN app's own tunnel | The app's tunnel is the source of the `100.64.0.2` collision (Section 1). The app may stay installed, but its tunnel must never be connected at the same time as Tailscale — see Section 6. |
| VPN Switch | Menu bar app (`app/VPNSwitch/`), SwiftUI `MenuBarExtra` | Independent status + toggles for both, driving `bin/vpn-ctl.sh`. |
| LAN DNS (dnsmasq) | **User** LaunchAgent, `dnsmasq` bound to `127.0.0.1:5354`, authoritative for `home.arpa` | Bare `streamy` / `mac-mini` resolve to LAN IPs at home when Tailscale is off, instead of returning no answer — [`docs/adr-003-lan-fallback.md`](adr-003-lan-fallback.md). |
| Scripts | `bin/vpn-ctl.sh`, `bin/dns-verify.sh`, `bin/dns-watch.sh`, `bin/dns-snapshot.sh`, `bin/nord-ikev2-profile.sh`, `bin/lan-dns-install.sh`, `bin/lan-dns-uninstall.sh`, `lib/*.sh` (incl. `lib/lan-dns.sh`, `lib/lan-hosts.sh`) | Control and verification, all read-only except `vpn-ctl.sh`'s toggles and the LAN DNS install/uninstall pair; see each script's own header for its contract. |

## 3. Setting up a fresh Mac

Do these in order.

### (a) Tailscale

Install the **standalone** build (not from the Mac App Store) and log in.
See `dns-config-p6t` for why the MAS build is unsuitable (no CLI, sandboxed).
After install, confirm the CLI is present: `tailscale version`.

### (b) NordVPN IKEv2 profile

Full runbook: [`docs/switcher/nord-ikev2-setup.md`](switcher/nord-ikev2-setup.md).
Four human steps, summarized:

1. **Get the IKEv2 server hostname** from Nord Account > Advanced settings >
   Server recommendation > IKEv2/IPSec (one specific server, not "NordVPN"
   generically).
2. **Get service credentials** from Nord Account > Service credentials — a
   separate, revocable username/password, not your account login.
3. **Run the generator**: `bash bin/nord-ikev2-profile.sh` with
   `NORD_IKEV2_SERVER` / `NORD_IKEV2_USER` / `NORD_IKEV2_PASS` (or
   `NORD_IKEV2_ENVFILE` pointing at a mode-600 file) set. It only writes a
   `.mobileconfig` file outside this repo — it never installs anything. The
   generator now also writes a DNS dictionary into the profile
   (`ServerAddresses` `103.86.96.100`/`103.86.99.100`, `SearchDomains`
   `home.arpa`) — controlled by the `NORD_IKEV2_DNS_SERVERS` and
   `NORD_IKEV2_SEARCH_DOMAINS` env vars (defaults shown above; set
   `NORD_IKEV2_SEARCH_DOMAINS=""` to disable the DNS dict entirely) — needed
   for LAN DNS bare-name expansion while the IKEv2 tunnel is primary; see
   step (e) below.
4. **Install it** via System Settings: open the generated file (Finder
   double-click or `open`), then approve it under **System Settings > Privacy
   & Security > Profiles**.

The profile **installs disabled**. Toggle it on once yourself under
**System Settings > VPN** to confirm it connects — this one-time manual
toggle is expected and is how you verify the profile before automating
anything.

### (c) The two Shortcuts

`vpn-ctl.sh` and the app control the profile through two Shortcuts you create
by hand — there is no CLI/`profiles` handle for a profile-installed VPN
config on this macOS. In Shortcuts.app, create:

- **`NordVPN On`** — action "Set VPN", target `NordVPN IKEv2`, mode
  **Connect**.
- **`NordVPN Off`** — same action, mode **Disconnect**.

Use exactly these two names, exactly these two modes. **Do not use mode
"Toggle"** for either — `vpn-ctl.sh` needs one-directional, idempotent
actions. Until both shortcuts exist, `vpn-ctl.sh nord on|off` exits **3**,
and the app's NordVPN toggle surfaces that same message instead of doing
anything. Full detail: [`docs/switcher/nord-ikev2-setup.md`](switcher/nord-ikev2-setup.md#shortcuts-for-nordvpn-control).

### (d) Install VPN Switch

```
bash bin/install-vpn-switch.sh
```

Builds the app, installs `vpn-ctl.sh`, its libs, and a copy of
`config/lan-hosts.conf` to `~/Library/Application
Support/vpn-switch/{bin,lib,config}/` (no sudo), and copies the app to
`/Applications/VPN Switch.app`. Safe to re-run. Re-run this after editing
`config/lan-hosts.conf` so the installed copy the app and `vpn-ctl.sh` use
stays in sync (`dns-config-1ww`) — see "Add a host" in
[`docs/hostnames/lan-dns.md`](hostnames/lan-dns.md).

The app is ad-hoc signed, so Gatekeeper may warn on first launch ("cannot be
opened because the developer cannot be verified"). Either right-click the
app in Finder and choose **Open** once, or clear the quarantine flag
directly: `xattr -dr com.apple.quarantine "/Applications/VPN Switch.app"`.

**Launch at login**: click the menu bar icon and toggle **Launch at login**
(uses `SMAppService`, visible/revocable under System Settings > General >
Login Items). Only enabled when running from `/Applications` — if disabled,
it shows "Install to /Applications first".

### (e) LAN DNS for bare names with Tailscale off

```
bash bin/lan-dns-install.sh
```

Installs dnsmasq (Homebrew) as a user LaunchAgent and renders the initial
`home.arpa` hosts file — no sudo. It then prints two one-time commands for a
human to run:

```
sudo mkdir -p /etc/resolver && printf 'nameserver 127.0.0.1\nport 5354\n' | sudo tee /etc/resolver/home.arpa
sudo networksetup -setsearchdomains "Wi-Fi" <existing search domains…> home.arpa
```

Copy the second command exactly as printed. That command **replaces** the
search domain list with `home.arpa` plus whatever else is already
configured — except `local`, which the script deliberately drops if
present (measured 2026-08-17: `local` as a search suffix makes bare names
wait on mDNS timing — up to ~5 s — before falling through to `home.arpa`
when this service is primary; see `docs/adr-003-lan-fallback.md` §1). Do
not add `local` back. The NordVPN IKEv2 profile generated in step
(b) already carries `home.arpa` in its `DNS.SearchDomains` — if that profile
was generated before this step existed, regenerate it
(`bash bin/nord-ikev2-profile.sh`) and reinstall it via System Settings so
bare names also expand while the IKEv2 tunnel is primary. Full detail:
[`docs/hostnames/lan-dns.md`](hostnames/lan-dns.md).

## 4. Daily use

Two independent toggles in the VPN Switch menu: **NordVPN** and
**Tailscale**. Toggling one never implicitly touches the other — coexistence
is the normal, supported state.

### Turn All VPNs On / Turn All VPNs Off

**Turn All VPNs On** and **Turn All VPNs Off** bring both up or down in one
click: NordVPN first, then Tailscale, in both directions. The Tailscale
half always runs, even if the NordVPN half fails, so a Nord failure never
leaves Tailscale stranded up (on "off") or stops Tailscale from coming up
(on "on"). CLI equivalents: `bash bin/vpn-ctl.sh all on` and
`bash bin/vpn-ctl.sh all off`.

No menu item — including these two — is ever disabled. Instead, clicks made
while a switch is already running are queued and run one `vpn-ctl.sh`
invocation at a time, in the order clicked. While a switch is in flight the
menu header shows `Switching: <action>…`, and if further switches are
waiting behind it, a `Queued: …` line lists them (a folded-in Refresh — see
below — is not listed).

The queue applies a few idempotency rules so rapid or repeated clicks don't
pile up redundant work:

- Clicking the same item again while it is already pending or running does
  nothing extra.
- Clicking the opposite state for the same VPN (e.g. NordVPN off, then on,
  before the first has run) replaces the pending intent — only the latest
  click for that target survives.
- A NordVPN intent and a Tailscale intent that target the same state and
  are **both still waiting** when the queue next picks up work collapse
  into a single `all on` (or `all off`) invocation. **Turn All VPNs
  On/Off** always produces one composite invocation this way; two separate
  clicks (NordVPN, then Tailscale) usually run as two commands instead,
  since the first is typically already running by the time the second is
  clicked — the merge only happens if the first click was still waiting
  behind something else when the second arrived.
- A queued action already satisfied by the latest known status is skipped
  when its turn comes up (nothing to do).
- **Refresh** is queued like any other action. If a switch is already
  pending or running, the refresh is folded into it — every switch
  re-reads status when it finishes — so clicking Refresh while a switch is
  in flight has no visible extra effect.

Each click records the target state computed from what the menu displayed
at the moment of the click, never a blind toggle — so a click's effect
doesn't change based on what happens to the status while it's waiting in
the queue.

Menu bar icon (SF Symbol, from `app/VPNSwitch/Sources/VPNSwitch/MenuIcon.swift`):

```
nord on,  ts on   -> "shield.lefthalf.filled.badge.checkmark"  (both connected)
nord on,  ts off  -> "checkmark.shield"                        (NordVPN only)
nord off, ts on   -> "network"                                 (Tailscale only)
nord off, ts off  -> "shield.slash"                             (both disconnected)
error/unknown     -> "exclamationmark.triangle"                (unknown/error state,
                                                                  e.g. app-tunnel/unrecognized)
```

**Both on is normal** — the whole point of the IKEv2 fix is that NordVPN and
Tailscale run simultaneously without conflict.

**⚠︎ (`exclamationmark.triangle`)** appears if the NordVPN **app**'s own
tunnel is detected (`nord=app` or `app+ikev2`) — this is the unsupported,
colliding configuration (Section 6). If you see it, disconnect the NordVPN
app's tunnel; do not leave it running alongside Tailscale.

**Needs login**: if Tailscale shows `NeedsLogin`, the app never attempts to
log in for you — it shows an **"Open Tailscale…"** menu item that opens the
Tailscale app so you can log in yourself.

**Bare names in every state.** `streamy` / `mac-mini` resolve to their
tailnet IPs while Tailscale is up, and to their LAN IPs while it is off at
home (ADR-003's LAN fallback, via dnsmasq/`home.arpa`). `streamy.home.arpa`
also works explicitly in any state. Worst case, after a Tailscale flip done
*outside* vpn-ctl (the Tailscale app's own menu rather than VPN Switch), a
bare name can serve the previous answer for up to ~10 s until the next
re-sync (`dns-config-qsk.12`); toggling via VPN Switch/`vpn-ctl.sh` measured
no such lag (+4 s to switch off, +1 s to switch back on, correct on the
first probe both times).

**External Tailscale changes re-sync the resolver too.** VPN Switch's poll
loop compares Tailscale's state across polls; when it observes a change
that VPN Switch itself did not initiate (the Tailscale app's own menu, a
reconnect, or a state change during sleep), it runs `vpn-ctl.sh lan-dns
sync` in the background so dnsmasq's answers follow within one poll
interval (default 5 s), the same way a VPN Switch-driven toggle already
does. This also runs once on wake, independent of whether a state change
was observed, since Tailscale can flip and flip back while asleep. It never
runs on steady-state polls and is silent housekeeping — failures are logged
(Console.app / `log show --predicate 'process == "VPNSwitch"'`) but never
shown in the menu bar UI.

### Updating

VPN Switch checks GitHub for a newer release automatically: 30 seconds after
launch, then every 24 hours, and again on wake if a check is due. These
background checks are **silent on failure** (logged only, never shown) and
**never modal** — they never activate the app or interrupt what you're
doing, and they **never auto-install**. If a newer release is found, the
menu header grows an extra line, `Update available: <version>`, and two new
items appear at the bottom of the menu: **"Install Update `<version>`…"**
and **"Skip This Version"**. There's also a **"Check for updates
automatically"** toggle in the menu (default on) if you want to turn the
background checks off entirely; turning it off does not hide an update
already found, it only stops future background checks.

**Skip This Version** dismisses that update without installing it and
remembers your choice — VPN Switch won't surface that exact version again,
but a *later* release still will. It's sticky across relaunches.

You can also check on demand: **"Check for Updates…"** in the menu. Unlike
the background check, this one always shows an alert: "You're up to date"
if there's nothing new, "VPN Switch `<version>` is available" with
**"Install and Relaunch"** / **Cancel** buttons if there is, or an error
alert if the check itself failed (no network, bad response, etc).

**Install flow.** Choosing to install (from either "Install Update …" in
the menu or "Install and Relaunch" in the manual-check alert) downloads the
release DMG, then verifies it two independent ways before touching
anything: the file's SHA-256 digest must match the one published in
`appcast.json`, **and** the file must pass Apple's notarization check
(`spctl`). Only if both pass does a small detached helper script swap the
new build into place at the app's current location (normally
`/Applications/VPN Switch.app`) and relaunch the app. The helper's own log is at `/tmp/vpn-switch-update.log` if you ever
need to see what an install actually did. If verification fails for either
reason, the downloaded file is discarded and the installed app is left
completely untouched — nothing partial or broken is ever put in place.

**The updater also pins the signing identity, not just notarization.**
Passing Apple's notarization check only proves a DMG is Developer-ID signed
and notarized by *some* Apple developer account — not necessarily VPN
Switch's own. So on top of the SHA-256 and notarization checks above, both
the downloaded DMG and the `.app` inside it (re-checked again, right before
install, on the mounted volume) must satisfy a designated requirement
pinning Team ID `Y5SB82BPYL`. This closes the gap where a compromised
GitHub account (a stolen release token, for example) could otherwise ship a
manifest pointing at an attacker's own notarized DMG: without VPN Switch's
actual Developer ID signing key, that DMG cannot satisfy the Team ID pin
and is refused. A DMG or app that is ad-hoc signed, unsigned, or signed by
a different Team ID is rejected: for the downloaded DMG, the app reports
the identity failure in its verification error and never launches the
helper; for the mounted app, the helper writes `refusing to install:
<bundle> does not satisfy the designated requirement (Team ID pin)` to
`/tmp/vpn-switch-update.log`, detaches the image, and exits. In both cases
the installed app is left untouched.

**Ad-hoc/dev builds cannot self-update.** This verification is by design:
a build that isn't signed with the project's Developer ID and notarized by
Apple will always fail the notarization check, so `bin/install-vpn-switch.sh`
builds (see below) never offer to self-update. This is not a bug to work
around.

**Scripts stay in sync automatically.** The app bundles its own copy of
`bin/vpn-ctl.sh`, `lib/*.sh`, and `config/lan-hosts.conf`. On every launch
it compares a version stamp (`.installed-version`) against what's already
installed under `~/Library/Application Support/vpn-switch` and re-copies
those files if they differ (or if `vpn-ctl.sh` is missing there). So a
self-update that only replaces the `.app` also brings the control scripts
up to date without needing to re-run `install-vpn-switch.sh`. The same sync
can be run headlessly with `VPNSwitch --sync-scripts`. Either way, the
scripts always *run* from Application Support, never from inside the
signed app bundle.

**Testing override.** To exercise the update-check loop without waiting a
full day, shorten the interval (minimum 60 seconds; anything lower is
clamped up to 60):

```bash
defaults write ie.boboco.vpnswitch updateCheckIntervalSeconds -int 60
```

Relaunch VPN Switch for the new interval to take effect.

## 5. Verifying

```
bash bin/dns-verify.sh
```

Runs a read-only PASS/FAIL/SKIP check table and a leading `State:` line
(`tailscale=<state> nordvpn=<mode> home-lan=<state> lan-dns=<state>`, where
`nordvpn` is `ikev2` | `app` | `app+ikev2` | `absent` and `lan-dns` is
`answering` | `not-answering` | `not-installed` — whether the dnsmasq
LaunchAgent itself is up and responding). Six checks in the healthy case (per
`docs/switcher/nord-ikev2-results.md`, §2: `bin/dns-verify.sh` → "6 passed, 0
failed, 0 skipped"): name resolution for both hosts, service reachability for
both (`streamy:5000/5001`, `mac-mini:22`), and staleness (resolved IPs
match the live Tailscale address when Tailscale is up, or `config/lan-hosts.conf`'s
LAN column when it is off). An additional check fires only if the NordVPN
app-tunnel/Tailscale collision is detected, and counts as a FAIL.

```
bash bin/vpn-ctl.sh lan-dns status
```

Reports the same `lan-dns=` state on its own, standalone from the full
`dns-verify.sh` run.

```
bash bin/vpn-ctl.sh status
```

One machine-readable line:
`nord=<up|down|app|app+ikev2|unknown> ts=<Running|Stopped|NeedsLogin|...> web=<ok|fail> streamy=<addr|fail>`.

```
bash bin/dns-watch.sh <label> 120
```

Polls every 2s for `<seconds>` (default 120) and logs to
`snapshots/<label>.log`. Start it **before** flipping a VPN, let it run
through the transition. **`WEB` is the decisive column** — a real HTTPS
fetch; DNS and ICMP can read green while the browser is dead, so trust `WEB`
over the others. Refuses to overwrite an existing log file (set
`DNS_WATCH_OVERWRITE=1` to force it deliberately).

```
bash bin/dns-snapshot.sh <label>
```

One-shot, read-only full capture of DNS/network state to
`snapshots/<label>.txt` (and stdout).

`vpn-ctl.sh` exit codes:

| Code | Meaning |
|---|---|
| 0 | Requested state verified (or already in it — no-op) |
| 1 | Timeout waiting for the requested state, or web verification failed |
| 2 | Tailscale `NeedsLogin` — human must log in via the menu bar app |
| 3 | A required NordVPN Shortcut ("NordVPN On"/"NordVPN Off") is missing |
| 4 | Deadlock guard: NordVPN app tunnel detected, refusing to start Tailscale |
| 5 | Usage error (bad/missing subcommand or action) |
| 6 | Another `vpn-ctl.sh` invocation holds the lock |

For `all on` and `all off`, the exit code is the first non-zero of (nord,
tailscale) for that direction — 0 only if both succeeded — and on failure a
one-line summary is printed to stderr naming which component(s) failed:
`vpn-ctl: all on: nord=<ok|failed (exit N)> tailscale=<ok|failed (exit N)>`
(and the analogous `vpn-ctl: all off: nord=<ok|failed (exit N)>
tailscale=<ok|failed (exit N)>` for `all off`).

**Headless checks.** `VPNSwitch --selftest-queue` runs the app's canned
menu-queue test cases against a fake runner — no `vpn-ctl.sh` invocation, no
VPN side effects — useful for verifying the queueing/idempotency rules
above without a live environment. **Warning:** the bare `--selftest` flag
(no `-queue` suffix) is not headless — it performs a live `nord on`.

## 6. Troubleshooting

| Symptom | Likely cause | Command / fix |
|---|---|---|
| Bare name fails, Tailscale is up | Tailscale is `NeedsLogin`, not actually connected | `tailscale status` — if `NeedsLogin`, open the Tailscale app and log in |
| Everything fails / "the network died" | NordVPN **app** tunnel is connected alongside Tailscale — the app's `100.64.0.2` resolver collides with Tailscale's own `100.64/10` claim | `bash bin/dns-verify.sh` — if `State:` shows `nordvpn=app` (or `app+ikev2`), disconnect the NordVPN app's tunnel |
| Tailscale stuck `Logged Out`/`NeedsLogin` after starting it under the app tunnel | Starting Tailscale while the NordVPN app's tunnel already holds the default route breaks the registration handshake (startup deadlock) | Open Tailscale, log in manually; going forward, never start Tailscale while the NordVPN app's tunnel is up — use the IKEv2 profile instead |
| Web fails with both up | Nord's pinned IKEv2 server (`de1545.nordvpn.com`) may be down/slow | Regenerate the profile for a different server: repeat Section 3(b) with a fresh hostname from Nord Account |
| App's NordVPN toggle says a shortcut is missing | The two Shortcuts ("NordVPN On"/"NordVPN Off") were never created | Create them per Section 3(c) |
| `vpn-ctl.sh` exits 6 | Lock held by another invocation | Stale locks from a dead pid are reclaimed automatically; if it's a live invocation, wait for it to finish |
| `scutil --nc` shows nothing for NordVPN | Expected — profile-installed IKEv2 configs live in NetworkExtension's own store, not classic SystemConfiguration, and `scutil --nc` cannot address them by name or UUID | Use System Settings > VPN (manual) or Shortcuts (`shortcuts run "NordVPN On"`) for control |
| `dns-verify.sh` reports `nordvpn=absent` while NordVPN is actually up | Stale/older script not using the shared detector | Update to the current `bin/dns-verify.sh` — detection keys on `ipsec0` presence and `103.86.x` resolvers |
| IKEv2 fails to connect | Service credentials expired/rotated, or CA trust issue | Regenerate the profile with fresh service credentials (Section 3(b), step 2-3); confirm the embedded CA in `config/nord-ikev2/nordvpn-root.der` is still valid |
| Tailscale IP of `streamy`/`mac-mini` changed | Real drift | `dns-verify.sh`'s staleness check catches this — it FAILs and names the mismatch |
| Bare name resolves to a LAN IP away from home / connection refused | Tailscale is off away from home — there is no path to the LAN IP | Turn Tailscale on; there is no design that has a correct answer for away + Tailscale off (ADR-003) |
| Bare name gives the previous answer for a few seconds after toggling Tailscale from its own menu | Resolver cache until the app/vpn-ctl re-syncs dnsmasq's hosts file (`dns-config-qsk.12`) | `bash bin/vpn-ctl.sh lan-dns sync` |
| Bare name fails with Tailscale off at home | dnsmasq not answering, or the search suffix isn't reaching the resolver | `bash bin/vpn-ctl.sh lan-dns status` (if not `answering`, run `bash bin/lan-dns-install.sh`); check `/etc/resolver/home.arpa` exists; check `scutil <<<'show State:/Network/Global/DNS'` — `SearchDomains` should contain `home.arpa` (if Nord IKEv2 is up and it doesn't, the profile predates the DNS block — regenerate with `bin/nord-ikev2-profile.sh` and reinstall) |
| Bare name takes ~5 s / no answer with both VPNs off, but `.home.arpa` is instant | `local` in the Wi-Fi search list (ahead of `home.arpa`) — bare names try `.local` mDNS first and wait ~5 s before falling through | `sudo networksetup -setsearchdomains "Wi-Fi" home.arpa` |

## 7. Tradeoffs and known limitations

- **Throughput, IKEv2 vs. NordLynx.** IKEv2 measured: 216.3 / 199.6 / 194.4
  Mbit/s (3 runs, 100MB from `ash-speed.hetzner.com`, Tailscale up,
  `dns-config-qsk.11`). **NordLynx (the app): UNMEASURED** — the comparison
  requires connecting the app, which was not done unattended.
- **No Threat Protection.** The app's DNS-based malware/ad/tracker blocking
  does not apply to a bare IKEv2 tunnel.
- **No kill switch.** A dropped IKEv2 tunnel fails open, unlike the app's
  always-on kill switch.
- **One pinned server** (`de1545.nordvpn.com`). No auto server selection;
  rotating servers means regenerating the profile by hand.
- **Plaintext service password** in the generated `.mobileconfig`, mode 600,
  written outside this repo. Not encrypted at rest — treat the file itself
  as a credential.
- **Profile is user-scoped and invisible to `scutil --nc`** — by design of
  NetworkExtension's separate config store, not a bug; control goes through
  Shortcuts instead.
- **Sleep/wake was NOT exercised.** The 12/12, 60s-soak result
  (`dns-config-qsk.10`) is a Tailscale restart under a live IKEv2 tunnel,
  not a sleep/wake cycle. Sleep/wake, Nord reconnect, and a longer soak are
  covered by `dns-config-qsk.11`; see
  [`docs/switcher/nord-ikev2-results.md`](switcher/nord-ikev2-results.md)
  for what is and is not measured.
- **Nord programmatic on/off is now measured.** The two Shortcuts
  ("NordVPN On"/"NordVPN Off", Section 3(c)) exist on this Mac, and NordVPN
  on/off via `vpn-ctl.sh` (the app's exact code path) is verified
  end to end: 2026-08-17, `nord off` +0 s, `nord on` +3 s, both leaving
  `dns-verify.sh` 6/6 afterward (see the L3/L4 rows and "Transition
  latency" in
  [`docs/verification-results.md`](verification-results.md)). **Still
  never measured** (see the NOT TESTED rows there): NordVPN toggled via the
  NordVPN app itself (as opposed to the IKEv2 profile/Shortcuts); the
  Nord-app-tunnel-present recovery test (connecting the app's own tunnel by
  hand and confirming detection/fix); away/hotspot networks (any row);
  sleep/wake.
- **Phones are unaffected by this fix.** iOS/Android allow only one VPN
  active at a time at the OS level — a standalone NordVPN client and
  Tailscale cannot coexist on a phone under any configuration.
- **The app cannot control the NordVPN app.** By design — VPN Switch only
  drives the IKEv2 profile via Shortcuts; it never launches, quits, or
  scripts the NordVPN app itself.
- **Notifications need a signed app for authorization.** The current ad-hoc
  build degrades silently (no prompt, no notifications) rather than erroring.
- **One more user-level daemon (dnsmasq) to keep alive** for the LAN DNS
  fallback (ADR-003) — `bin/vpn-ctl.sh lan-dns status` / `dns-verify.sh`'s
  `lan-dns=` token report whether it is answering.
- **LAN addresses in `config/lan-hosts.conf` can go stale under DHCP** —
  use DHCP reservations or static addresses for hosts listed there.
- **Away from home with Tailscale off has no correct answer by design** —
  the LAN IP dnsmasq serves is unreachable off the LAN; there is no
  design that fixes this state (ADR-003).
- **Two one-time sudo steps at LAN DNS install** (`/etc/resolver/home.arpa`,
  `networksetup -setsearchdomains`) — the only root steps anywhere in this
  project.

## 8. Uninstall / undo everything

```
bash bin/uninstall-vpn-switch.sh
```

Quits the app, unregisters the login item, and removes `/Applications/VPN
Switch.app` and the installed `bin/`/`lib/`/`config/` scripts. Deliberately leaves
behind (and prints a note about) the IKEv2 profile and any
`.mobileconfig`/`.env` files under `~/Library/Application
Support/vpn-switch/` — **this includes NordVPN service credentials**, so
delete that directory yourself if you want them gone.

To remove the rest by hand:

- **IKEv2 profile**: System Settings > Privacy & Security > Profiles, select
  `NordVPN IKEv2`, remove it. Or: `profiles remove -identifier
  ie.boboco.vpn-switch.nordvpn-ikev2`.
- **The two Shortcuts**: delete "NordVPN On" / "NordVPN Off" in Shortcuts.app.
- **Credentials directory**: `rm -rf "$HOME/Library/Application
  Support/vpn-switch"` (contains the `.mobileconfig`, which has your NordVPN
  service password in plaintext).
- **Stale Tailscale nodes**: the investigation that led here left stale nodes
  (`this-mac-userspace`, an old `this-mac`) registered in the Tailscale admin
  console — optional cleanup, tracked as `dns-config-r5b`.

To remove the LAN DNS fallback (ADR-003):

```
bash bin/lan-dns-uninstall.sh
```

Unloads the dnsmasq LaunchAgent and removes the generated dnsmasq
config/logs, the rendered hosts file, and the pid file — no sudo. It
deliberately leaves `config/lan-hosts.conf` (repo source) and does not run
`brew uninstall dnsmasq` in place. It then prints, but does not run, the
matching root-level undo:

```
sudo rm /etc/resolver/home.arpa
sudo networksetup -setsearchdomains "Wi-Fi" <remaining search domains…>
```

(the second command reflects each active network service's search domain
list with `home.arpa` removed). Optionally, `brew uninstall dnsmasq` if
nothing else on the machine uses it. If you also want to remove the
`DNS.SearchDomains` key from the NordVPN IKEv2 profile, regenerate it with
`NORD_IKEV2_SEARCH_DOMAINS=""` and reinstall.

## 9. Repo map

- `bin/` — entry-point scripts: `vpn-ctl.sh` (control), `dns-verify.sh`
  (one-shot check), `dns-watch.sh` (polling capture), `dns-snapshot.sh`
  (one-shot capture), `nord-ikev2-profile.sh` (profile generator),
  `install-vpn-switch.sh` / `uninstall-vpn-switch.sh`,
  `lan-dns-install.sh` / `lan-dns-uninstall.sh` (ADR-003 LAN DNS fallback).
- `lib/` — shared, sourceable logic: `nord-ctl.sh`, `nord-detect.sh`,
  `tailscale-ctl.sh`, `lan-dns.sh` (dnsmasq LaunchAgent status/sync),
  `lan-hosts.sh` (renders `config/lan-hosts.conf` into dnsmasq's hosts file).
- `app/` — the VPN Switch SwiftUI menu bar app (`app/VPNSwitch/`).
- `config/lan-hosts.conf` — source of LAN/tailnet addresses for the LAN DNS
  fallback (ADR-003); one line per host.
- `docs/` — `adr-001-hostname-resolution.md` (superseded by ADR-002, kept for
  its corrected-mechanism appendix), `adr-002-nordvpn-ikev2.md` (current
  decision), `adr-003-lan-fallback.md` (LAN DNS fallback for Tailscale-off),
  `findings.md` (full narrative), `research/` (background: technical,
  community reports, vendor positions), `switcher/` (design and setup docs
  for the IKEv2 profile, Tailscale control, and the app), `hostnames/`
  (LAN DNS design/measurements: `lan-dns.md`, `search-domain-results.md`).
- `snapshots/` — evidence captures. Filenames are labels; `dns-watch.sh`
  refuses to overwrite an existing one.
- `config/nord-ikev2/` — the NordVPN IKEv2 root CA only (public, safe to
  commit). No credentials live in this repo.

## Releasing

This section is for whoever cuts a VPN Switch release — most days you don't
need it; see "Updating" (Section 4) for how a release actually reaches an
already-installed Mac.

**Prerequisites (one-time setup):**

- A **Developer ID Application** code-signing identity installed in the
  login keychain. `app/build.sh`/`app/release/make-dmg.sh` auto-detect it
  (via `app/release/lib/resolve-codesign-identity.sh`); an ad-hoc-only
  keychain refuses to produce a distributable DMG unless you explicitly
  override it.
- Notarization credentials, either:
  - `xcrun notarytool store-credentials VPNSwitchNotary --key <path-to-AuthKey_XXXX.p8> --key-id <key-id> --issuer <issuer-id>`
    (stores a keychain profile named `VPNSwitchNotary`, App Store Connect
    API key from Users and Access > Integrations), **or**
  - if you already have a stored profile from another project on the same
    Apple Developer account, reuse it: `export NOTARY_PROFILE=GateOpenerNotary`.
    You don't even need to set `NOTARY_PROFILE` for this — with it unset,
    `make notarize` (and `make cut`) tries `VPNSwitchNotary` first, then
    falls back to `GateOpenerNotary` automatically, using whichever one is
    actually present in the keychain.
- `gh auth login` — `make release` publishes via `gh release create`.

**One-shot.** `make cut VERSION=0.5.0` (or `/release 0.5.0` in Claude Code)
runs the entire sequence below — steps 1-5 plus the push in between — as a
single command: bump the version, commit, `git push origin main`, `make dmg`,
`make notarize`, `make release`, then verify the published `appcast.json`
actually reports the new version (retrying briefly, since GitHub's `latest`
redirect can lag). It fails fast, before the next irreversible step, if any
stage fails, and if the push already succeeded before a later stage fails, it
says so explicitly — `make notarize` / `make release` are safe to re-run by
hand in that case. Notarization credentials are resolved the same way as
`make notarize` below: a `VPNSwitchNotary` keychain profile first, falling
back automatically to `GateOpenerNotary` if that's what's actually stored.
`CUT_DRY_RUN=1 make cut VERSION=0.5.0` previews every step (including all
preconditions, checked for real) without changing or publishing anything.
The manual sequence below remains useful for troubleshooting a single step
in isolation.

**Release sequence (manual):**

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in
   `app/VPNSwitch/Info.plist`.
2. Commit that change. (`make release` refuses to run against a dirty
   working tree — see below.)
3. `make dmg` — builds the app from source (release configuration),
   code-signs it with the resolved Developer ID identity, and assembles a
   distributable DMG at `app/build/VPNSwitch-<version>.dmg`. Refuses an
   ad-hoc signature unless you explicitly opt in.
4. `make notarize` — submits that DMG to Apple's notarization service,
   waits for a result, staples the ticket, and verifies the stapled DMG
   actually satisfies Gatekeeper (`spctl -a -t open --context
   context:primary-signature`). This is a real network round trip and can
   take several minutes; never run as a side effect of `make dmg` or `make
   release`.
5. `make release` — publishes the GitHub release. Before doing anything, it
   checks: `origin` resolves to `github.com/ebowman/vpn-switch` (the exact
   host/owner/repo the app's own updater pins downloads to); the working
   tree is clean; the tag `v<version>` doesn't already exist locally or on
   `origin`; and the built DMG exists and re-passes the same notarization
   check as step 4. Only if every check passes does it generate
   `appcast.json` (fields `latestVersion`, `notes`, `dmgURL`, `dmgSHA256` —
   the SHA is computed from the exact DMG file that was just verified) and
   run `gh release create` to publish tag `v<version>`, release title "VPN
   Switch v<version>", with both `VPNSwitch-<version>.dmg` and
   `appcast.json` attached as release assets.

**Why `appcast.json`'s name never changes.** The manifest is always named
`appcast.json`, release after release — never versioned — because that's
what makes GitHub's `releases/latest/download/appcast.json` URL always
redirect to the manifest for the *most recent* release, without the
running app needing to know a version number in advance
(`UpdateFetcher.manifestURLString`). The DMG, by contrast, IS versioned
(`VPNSwitch-<version>.dmg`) so multiple releases' DMGs can coexist as
separate assets. Do not "fix" this asymmetry.

All release artefacts (`app/build/VPNSwitch.app`, the DMG, `appcast.json`)
live under `app/build`, which is gitignored — nothing under it is ever
committed.

**Bootstrap note.** The very first Developer-ID-signed build has to be
installed by hand with `bin/install-vpn-switch.sh` (Section 3(d)) — a
previously-installed ad-hoc build has no self-updater capable of pulling
it in (ad-hoc signatures always fail the notarization gate; see
"Updating" above). After that first hand-installed Developer-ID build is
in place, every later release is picked up by the app's own automatic or
manual update check — you do not need to run `install-vpn-switch.sh`
again just to pick up a new version.

**Development.** Day-to-day build/test, independent of the release
pipeline above:

```bash
make build   # swift build --package-path app/VPNSwitch
make test    # swift test --package-path app/VPNSwitch
```

CI (`.github/workflows/ci.yml`) runs the same build and test on
`macos-latest` for every push/PR to `main`, plus a shell syntax check
(`bash -n bin/*.sh lib/*.sh`).

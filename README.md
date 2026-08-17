# dns-config

VPN Switch's runbook for this Mac: what runs, how to set up a fresh machine,
daily use, verification, troubleshooting, tradeoffs, and uninstall. This
document assumes the **final** setup — Tailscale standalone + NordVPN over a
native IKEv2 profile + the VPN Switch menu bar app. For the full narrative of
how that setup was arrived at (what broke, what was tried, what was
measured), see [`docs/findings.md`](docs/findings.md); for the decision
record, see [`docs/adr-002-nordvpn-ikev2.md`](docs/adr-002-nordvpn-ikev2.md).
This README does not repeat either — it links them.

## 0. The 30-second version (read this first)

**How do I turn NordVPN on or off now?** Not with the NordVPN app — that is
the one thing that must stay disconnected (its tunnel collides with
Tailscale). Use either:

- **VPN Switch** (menu bar) → click **NordVPN**. *Requires the two Shortcuts
  below to exist; until then the toggle shows a message telling you so.*
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
API alone. Full story: [`docs/findings.md`](docs/findings.md). Decision:
[`docs/adr-002-nordvpn-ikev2.md`](docs/adr-002-nordvpn-ikev2.md).

## 2. What runs on the Mac

| Component | What it is | Why |
|---|---|---|
| Tailscale | **Standalone build** (not the Mac App Store build) | Sandboxed MAS build has no `tailscale` CLI on PATH and withholds most config surface; the standalone build is needed for the real CLI (`dns-config-p6t`). |
| NordVPN | **Native IKEv2 configuration profile** — NOT the NordVPN app's own tunnel | The app's tunnel is the source of the `100.64.0.2` collision (Section 1). The app may stay installed, but its tunnel must never be connected at the same time as Tailscale — see Section 6. |
| VPN Switch | Menu bar app (`app/VPNSwitch/`), SwiftUI `MenuBarExtra` | Independent status + toggles for both, driving `bin/vpn-ctl.sh`. |
| Scripts | `bin/vpn-ctl.sh`, `bin/dns-verify.sh`, `bin/dns-watch.sh`, `bin/dns-snapshot.sh`, `bin/nord-ikev2-profile.sh`, `lib/*.sh` | Control and verification, all read-only except `vpn-ctl.sh`'s toggles; see each script's own header for its contract. |

## 3. Setting up a fresh Mac

Do these in order.

### (a) Tailscale

Install the **standalone** build (not from the Mac App Store) and log in.
See `dns-config-p6t` for why the MAS build is unsuitable (no CLI, sandboxed).
After install, confirm the CLI is present: `tailscale version`.

### (b) NordVPN IKEv2 profile

Full runbook: [`docs/switcher/nord-ikev2-setup.md`](docs/switcher/nord-ikev2-setup.md).
Four human steps, summarized:

1. **Get the IKEv2 server hostname** from Nord Account > Advanced settings >
   Server recommendation > IKEv2/IPSec (one specific server, not "NordVPN"
   generically).
2. **Get service credentials** from Nord Account > Service credentials — a
   separate, revocable username/password, not your account login.
3. **Run the generator**: `bash bin/nord-ikev2-profile.sh` with
   `NORD_IKEV2_SERVER` / `NORD_IKEV2_USER` / `NORD_IKEV2_PASS` (or
   `NORD_IKEV2_ENVFILE` pointing at a mode-600 file) set. It only writes a
   `.mobileconfig` file outside this repo — it never installs anything.
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
anything. Full detail: [`docs/switcher/nord-ikev2-setup.md`](docs/switcher/nord-ikev2-setup.md#shortcuts-for-nordvpn-control).

### (d) Install VPN Switch

```
bash bin/install-vpn-switch.sh
```

Builds the app, installs `vpn-ctl.sh` and its libs to `~/Library/Application
Support/vpn-switch/{bin,lib}/` (no sudo), and copies the app to
`/Applications/VPN Switch.app`. Safe to re-run.

The app is ad-hoc signed, so Gatekeeper may warn on first launch ("cannot be
opened because the developer cannot be verified"). Either right-click the
app in Finder and choose **Open** once, or clear the quarantine flag
directly: `xattr -dr com.apple.quarantine "/Applications/VPN Switch.app"`.

**Launch at login**: click the menu bar icon and toggle **Launch at login**
(uses `SMAppService`, visible/revocable under System Settings > General >
Login Items). Only enabled when running from `/Applications` — if disabled,
it shows "Install to /Applications first".

## 4. Daily use

Two independent toggles in the VPN Switch menu: **NordVPN** and
**Tailscale**. Toggling one never implicitly touches the other — coexistence
is the normal, supported state.

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

## 5. Verifying

```
bash bin/dns-verify.sh
```

Runs a read-only PASS/FAIL/SKIP check table and a leading `State:` line
(`tailscale=<state> nordvpn=<mode> home-lan=<state>`, where `nordvpn` is
`ikev2` | `app` | `app+ikev2` | `absent`). Six checks in the healthy case (per
`docs/switcher/nord-ikev2-results.md`, §2: `bin/dns-verify.sh` → "6 passed, 0
failed, 0 skipped"): name resolution for both hosts, service reachability for
both (`streamy:5000/5001`, `mac-mini:22`), and staleness (resolved IPs
match the live Tailscale address). An additional check fires only if the
NordVPN app-tunnel/Tailscale collision is detected, and counts as a FAIL.

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
- **Sleep/wake and long-term durability are only partially measured.** A
  Tailscale restart under a live IKEv2 tunnel was tested and held (12/12
  samples, 60s soak, `dns-config-qsk.10`). Sleep/wake, Nord reconnect, and a
  longer soak are covered by `dns-config-qsk.11`; see
  [`docs/switcher/nord-ikev2-results.md`](docs/switcher/nord-ikev2-results.md)
  for what is and is not measured.
- **Phones are unaffected by this fix.** iOS/Android allow only one VPN
  active at a time at the OS level — a standalone NordVPN client and
  Tailscale cannot coexist on a phone under any configuration.
- **The app cannot control the NordVPN app.** By design — VPN Switch only
  drives the IKEv2 profile via Shortcuts; it never launches, quits, or
  scripts the NordVPN app itself.
- **Notifications need a signed app for authorization.** The current ad-hoc
  build degrades silently (no prompt, no notifications) rather than erroring.

## 8. Uninstall / undo everything

```
bash bin/uninstall-vpn-switch.sh
```

Quits the app, unregisters the login item, and removes `/Applications/VPN
Switch.app` and the installed `bin/`/`lib/` scripts. Deliberately leaves
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

## 9. Repo map

- `bin/` — entry-point scripts: `vpn-ctl.sh` (control), `dns-verify.sh`
  (one-shot check), `dns-watch.sh` (polling capture), `dns-snapshot.sh`
  (one-shot capture), `nord-ikev2-profile.sh` (profile generator),
  `install-vpn-switch.sh` / `uninstall-vpn-switch.sh`.
- `lib/` — shared, sourceable logic: `nord-ctl.sh`, `nord-detect.sh`,
  `tailscale-ctl.sh`.
- `app/` — the VPN Switch SwiftUI menu bar app (`app/VPNSwitch/`).
- `docs/` — `adr-001-hostname-resolution.md` (superseded by ADR-002, kept for
  its corrected-mechanism appendix), `adr-002-nordvpn-ikev2.md` (current
  decision), `findings.md` (full narrative), `research/` (background:
  technical, community reports, vendor positions), `switcher/` (design and
  setup docs for the IKEv2 profile, Tailscale control, and the app).
- `snapshots/` — evidence captures. Filenames are labels; `dns-watch.sh`
  refuses to overwrite an existing one.
- `config/nord-ikev2/` — the NordVPN IKEv2 root CA only (public, safe to
  commit). No credentials live in this repo.

# dns-config

## VPN Switch — install

VPN Switch is a menu bar app that shows the live status of NordVPN (native
IKEv2 profile, not the NordVPN app) and Tailscale, and lets you toggle each
independently. It drives `bin/vpn-ctl.sh`; see that script's header comment
for the full behavior contract, and `docs/switcher/` for the design record.

### Prerequisites

- Xcode or the Xcode Command Line Tools (for `swift build`).
- The NordVPN IKEv2 profile installed — see
  `docs/switcher/nord-ikev2-setup.md`.
- The two Shortcuts the app's NordVPN toggle depends on ("NordVPN On" /
  "NordVPN Off") — see `docs/switcher/nord-ikev2-setup.md`.

### Install

```
bash bin/install-vpn-switch.sh
```

This builds the app, installs `vpn-ctl.sh` and its libs to
`~/Library/Application Support/vpn-switch/{bin,lib}/` (no sudo), and copies
the app to `/Applications/VPN Switch.app`. Safe to re-run — it updates
everything in place. It never touches the IKEv2 profile, NordVPN
credentials, or Shortcuts.app.

An opt-in `/usr/local` install location for the scripts exists for people
who prefer a system-wide path: `INSTALL_PREFIX=/usr/local bash
bin/install-vpn-switch.sh`. This prints the exact `sudo` commands to run —
the script itself never calls `sudo`.

### First launch

```
open "/Applications/VPN Switch.app"
```

The app is ad-hoc signed, so Gatekeeper may warn the first time you open it
("cannot be opened because the developer cannot be verified"). Either:

- Right-click (or Control-click) the app in Finder and choose **Open**, then
  confirm in the dialog that appears — this only needs to be done once, or
- if the app was quarantined by download/AirDrop, clear the quarantine flag
  directly: `xattr -dr com.apple.quarantine "/Applications/VPN Switch.app"`

### Launch at login

Click the menu bar icon and toggle **Launch at login**. This uses
`SMAppService`, so it shows up in System Settings > General > Login Items,
where you can also revoke it directly. The toggle is only enabled when the
app is running from `/Applications` (a stable path is required); if it's
disabled, it shows the hint "Install to /Applications first".

### Uninstall

```
bash bin/uninstall-vpn-switch.sh
```

Quits the app, unregisters the login item, and removes the app and the
installed `bin/`/`lib/` scripts. It leaves the IKEv2 profile and any
`.env`/`.mobileconfig` files under
`~/Library/Application Support/vpn-switch/` in place — those are a separate
concern from this app and are never touched by install or uninstall.

### What this app does NOT do

- No auto-fix: it reports state and lets you toggle, it doesn't retry or
  repair a broken VPN state on its own.
- No login: it never drives Tailscale's login flow — if Tailscale needs
  login, the app just opens the Tailscale app for you.
- No NordVPN app control: it only controls the native IKEv2 profile via
  Shortcuts. It never launches, quits, or scripts the NordVPN app itself.

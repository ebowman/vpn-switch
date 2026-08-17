# NordVPN macOS control surfaces (static inspection)

Read-only inspection of `/Applications/NordVPN.app` (version 10.8.1) for
`dns-config-qsk.2`. No connect/disconnect action was performed against
NordVPN at any point. Findings below feed the live test in `qsk.3`.

Bundle ID of the main app: `com.nordvpn.macos` (from
`PlistBuddy -c 'Print :CFBundleIdentifier' Contents/Info.plist`).

## 1. URL schemes

`Info.plist` declares three `CFBundleURLTypes`:

```
CFBundleURLTypes = Array {
    Dict { CFBundleTypeRole = Editor; CFBundleURLSchemes = Array { nordvpn } }
    Dict { CFBundleTypeRole = ...   ; CFBundleURLSchemes = Array { nordvpn-sl } }
    Dict { CFBundleTypeRole = ...   ; CFBundleURLSchemes = Array { meshnet } }
}
```

`strings -a` was run over every Mach-O binary in the bundle: `Contents/MacOS/NordVPN`,
all `Contents/Frameworks/*.framework/Versions/A/<name>` binaries, the login item
(`Contents/Library/LoginItems/NordVPNLauncher Sideload.app/Contents/MacOS/...`),
the system extension (`Contents/Library/SystemExtensions/com.nordvpn.macos.Shield.systemextension/Contents/MacOS/...`),
and the three `.nnex` tunnel-extension binaries under `Contents/PlugIns`.

**No literal `nordvpn://` or `meshnet://` URL strings exist in any binary.** The
scheme that is actually used in code is `nordvpn-app://` (not the bare
`nordvpn://` from the plist), alongside `nordvpn-sl://`. The identical set of
20 literal path strings appears in every binary that has any hits at all
(main app, Shield extension, and all three `.nnex` tunnel extensions — the
Shield extension binary has it duplicated per-architecture, hence "40" grep
hits for a fat binary):

```
nordvpn-app://login                                          nordvpn-sl://login
nordvpn-app://mfa_finished                                   nordvpn-sl://mfa_finished
nordvpn-app://openDetectedLeaks                               nordvpn-sl://openDetectedLeaks
nordvpn-app://download_nord_drop                               nordvpn-sl://download_nord_drop
nordvpn-app://openMeshInvite                                   nordvpn-sl://openMeshInvite
nordvpn-app://autoConnectSettings                              nordvpn-sl://autoConnectSettings
nordvpn-app://invisible_on_lan_secure_connection_show_more     nordvpn-sl://invisible_on_lan_secure_connection_show_more
nordvpn-app://invisible_on_lan_secure_connection_show_more_in_app  nordvpn-sl://invisible_on_lan_secure_connection_show_more_in_app
nordvpn-app://invisible_on_lan_not_secure_connection_show_more nordvpn-sl://invisible_on_lan_not_secure_connection_show_more
                                                                nordvpn-sl://claim-online-purchase
                                                                nordvpn-sl://updateNow
```

Context (`Contents/MacOS/NordVPN`, `strings -a` output, lines ~240220-240290,
same block repeated later in the fat binary at ~366491-366542):

```
...
certificate leaf[field.1.2.840.113635.100.6.1.9]
nordvpn-sl://claim-online-purchase
https://nord-apps.com
com.nordvpn.macos.NetworkTunnelExtension
...
/checkout/nordvpn/
CommonModule/Constants.swift
Missing call Constants.configure in AppDelegate
nordvpn-app://login
nordvpn-sl://login
nordvpn-app://mfa_finished
nordvpn-sl://mfa_finished
nordvpn-app://openDetectedLeaks
nordvpn-sl://openDetectedLeaks
nordvpn-app://download_nord_drop
nordvpn-sl://download_nord_drop
nordvpn-app://openMeshInvite
nordvpn-sl://openMeshInvite
nordvpn-app://autoConnectSettings
nordvpn-sl://autoConnectSettings
nordvpn-app://invisible_on_lan_secure_connection_show_more
nordvpn-sl://invisible_on_lan_secure_connection_show_more
nordvpn-app://invisible_on_lan_secure_connection_show_more_in_app
nordvpn-sl://invisible_on_lan_secure_connection_show_more_in_app
nordvpn-app://invisible_on_lan_not_secure_connection_show_more
nordvpn-sl://invisible_on_lan_not_secure_connection_show_more
nordvpn-sl://updateNow
x-apple.systempreferences:com.apple.preference.security?General
specialty_servers/
country_regions_list_popup
```

**Verdict: no `connect` / `disconnect` / `quick-connect` / `country` / `server`
URL action exists.** Every path is a deep link into a UI screen (login flow,
MFA, meshnet invite acceptance, leak-detection panel, auto-connect settings
screen, LAN-visibility explainer, update prompt, purchase claim). There is no
URL-routing table with imperative verbs — this looks like a Branch/Firebase
deferred-deep-link table for onboarding/marketing flows, not a control API.

Supporting evidence from symbol names in `Contents/MacOS/NordVPN` (grep for
`deeplink`/`DeepLink`, case-insensitive, ~102 hits): `DeepLinkServiceProcessor`,
`DeepLinkServiceCoordinator`, `DeepLinkMeshnetCoordinator`,
`DeepLinkMeshnetService`, `handleOpenURL:`, `handleDeepLink:...`,
`deepLinkURLScheme`, `relevantURLSchemes`, `NordVPN.DeepLinkServiceProcessor`
— all navigation/analytics plumbing (Firebase `GOOGLE_ANALYTICS_DEFERRED_DEEP_LINK_ENABLED`
appears in the same strings region), not a VPN-state action dispatcher.

Also searched for `quickConnect` / `ConnectIntent` / `DisconnectIntent` tokens
(present as internal Swift symbol/log strings, e.g.
`NordWhisper/NordWhisper+ConnectIntent.swift`, `[ConnectIntent] Failed in
state:`, `trackDisconnectIntent(startDate:)`, `widgetQuickConnect`,
`statusBarQuickConnect`). These are internal `NEPacketTunnelProvider`
state-machine intents and SwiftUI element identifiers (menu bar popover /
widget button accessibility ids) — not `INIntent`/Shortcuts App Intents (no
`INIntentHandler`, `donateInteraction`, or `ShortcutsIntent` strings found
anywhere) and not exposed via any URL route.

**Result: no usable URL-scheme action found.** `nordvpn://`, `nordvpn-sl://`,
`meshnet://` can only open UI screens already reachable another way; none
starts/stops the tunnel.

## 2. Embedded helpers

```
$ ls -R Contents/Library Contents/PlugIns Contents/XPCServices Contents/Frameworks (top level)
Contents/Library:
LaunchServices
LoginItems
SystemExtensions

Contents/Library/LaunchServices:
com.nordvpn.macos.helper

Contents/Library/LoginItems:
NordVPNLauncher Sideload.app

Contents/Library/SystemExtensions:
com.nordvpn.macos.Shield.systemextension

Contents/PlugIns:
NordLynx Extension Sideload.nnex
OpenVPN Extension Sideload.nnex
NordWhisper Extension Sideload.nnex

Contents/XPCServices:
<does not exist> (only Contents/Frameworks/Sparkle.framework/XPCServices was found, i.e. Sparkle's
own updater XPC service, not a NordVPN-specific one)

Contents/Frameworks (top level only):
CocoaLumberjack.framework   GoogleAppMeasurementIdentitySupport.framework  quenchFFI.framework
FirebaseAnalytics.framework Lottie.framework                               Realm.framework
firewallFFI.framework       norddropFFI.framework                          RealmSwift.framework
GoogleAppMeasurement.framework  nordvpnappFFI.framework                    Sparkle.framework
                                nudlerFFI.framework                        telioFFI.framework
                                                                            vinisFFI.framework
                                                                            workerFFI.framework
```

Bundle IDs (via `PlistBuddy -c 'Print :CFBundleIdentifier'` on each bundle's
`Info.plist`):

| Path | Bundle ID |
|---|---|
| `Contents/Library/LoginItems/NordVPNLauncher Sideload.app` | `com.nordvpn.macos.NordVPNLauncher` |
| `Contents/Library/SystemExtensions/com.nordvpn.macos.Shield.systemextension` | `com.nordvpn.macos.Shield` |
| `Contents/PlugIns/NordLynx Extension Sideload.nnex` | `com.nordvpn.macos.NordLynx` |
| `Contents/PlugIns/NordWhisper Extension Sideload.nnex` | `com.nordvpn.macos.NordWhisperTunnel` |
| `Contents/PlugIns/OpenVPN Extension Sideload.nnex` | `com.nordvpn.macos.NetworkTunnelExtension` |
| `Contents/Library/LaunchServices/com.nordvpn.macos.helper` | not a bundle — a bare Mach-O executable named by convention; installed system-wide as `/Library/PrivilegedHelperTools/com.nordvpn.macos.helper` (seen running as root in `ps aux`, PID 39922) |

`systemextensionsctl list` output (verbatim, full):

```
6 extension(s)
--- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
enabled	active	teamID	bundleID (version)	name	[state]
*	*	MLZF7K7B5R	at.obdev.littlesnitch.networkextension (6.4.1/7212)	Little Snitch Network Extension	[activated enabled]
*	*	W5364U7YZB	io.tailscale.ipn.macsys.network-extension (1.102.2/101.102.2)	Tailscale Network Extension	[activated enabled]
--- com.apple.system_extension.endpoint_security (Go to 'System Settings > General > Login Items & Extensions > Endpoint Security Extensions' to modify these system extension(s))
enabled	active	teamID	bundleID (version)	name	[state]
*	*	W5W395V82Y	com.nordvpn.macos.Shield (10.8.1/371)	NordVPN protection	[activated enabled]
		W5W395V82Y	com.nordvpn.macos.Shield (10.8.0/370)	NordVPN protection	[terminated waiting to uninstall on reboot]
*	*	MLZF7K7B5R	at.obdev.littlesnitch.endpointsecurity (6.4.1/7212)	Little Snitch Endpoint Security	[activated enabled]
--- com.apple.system_extension.driver_extension (Go to 'System Settings > General > Login Items & Extensions > Driver Extensions' to modify these system extension(s))
enabled	active	teamID	bundleID (version)	name	[state]
*	*	G43BCU2T37	org.pqrs.Karabiner-DriverKit-VirtualHIDDevice (1.8.0/1.8.0)	org.pqrs.Karabiner-DriverKit-VirtualHIDDevice	[activated enabled]
```

**Important observation**: `com.nordvpn.macos.Shield` is registered under the
**endpoint_security** category (this is Nord's Threat Protection / malware
scanning extension), currently `activated enabled`, plus a stale
`10.8.0` copy `[terminated waiting to uninstall on reboot]`. There is **no
NordVPN entry under `network_extension`** — the category that would host the
actual tunnel provider (NordLynx/OpenVPN/NordWhisper). This means the current
running VPN tunnel, if any, is *not* implemented as an installed macOS System
Extension network extension right now (or it's a `NEPacketTunnelProvider`
that isn't listed here because it's an app-extension-based tunnel managed
through `NEVPNManager`/`NETunnelProviderManager` rather than
`systemextensionsctl`, which only tracks the newer System Extension
mechanism). The three `.nnex` PlugIns bundles (`NordLynx`, `OpenVPN`,
`NordWhisper` "Extension Sideload") are Network Extension *app extensions*
bundled in `Contents/PlugIns` — visible in `~/Library/Containers/` as
sandboxed containers (`com.nordvpn.macos.NetworkTunnelExtension`,
`com.nordvpn.macos.NordLynx`, `com.nordvpn.macos.NordWhisperTunnel`), which
matches the classic `NEPacketTunnelProvider` app-extension pattern, not the
new-style system extension. **Open question for qsk.3**: with no NordVPN
network_extension activated per `systemextensionsctl`, does the tunnel run
through `NEVPNManager` app-extension plumbing that this listing simply
doesn't surface? Test by checking `scutil --nc list` / `ifconfig` for an
active NordVPN utun interface while connected.

## 3. Defaults

Domain: `com.nordvpn.macos` (derived from `CFBundleIdentifier`).
`defaults read com.nordvpn.macos` succeeded (read-only). A second domain,
`group.com.nordvpn.macos.firebase`, exists but contains only Firebase remote
config cache metadata (`activeTemplateVersion`, `lastETag`, etc.) — not
relevant to VPN control.

Files on disk (read-only `ls`):

```
~/Library/Preferences/com.nordvpn.macos.plist            (7935 bytes, mtime 2026-08-16 11:35)
~/Library/Preferences/group.com.nordvpn.macos.firebase.plist  (266 bytes, mtime 2026-08-16 11:23)
```

No `~/Library/Group Containers` entry matching `nord`. Sandboxed containers
exist under `~/Library/Containers/` for the three tunnel-extension bundle IDs
listed above (empty of readable prefs at top-level `ls`).

Relevant keys and **current values** from `defaults read com.nordvpn.macos`:

| Key | Current value | Notes |
|---|---|---|
| `isAutoConnectOn` | `0` | Auto-connect is off right now. Plausibly `defaults write`-able but untested. |
| `killSwitchEnabled` | `1` | Kill switch is ON. If the switcher toggles VPN off via a blunt method (quit/killall), a kill-switch-enabled state could block all network traffic until Nord's helper/extension tears down cleanly — a serious edge case for qsk.3. |
| `connectOnDemand` | `0` | "Connect on demand" off. |
| `vpnProtocol` | `"openvpn_udp"` | Current/last-used tunnel protocol — explains why `com.nordvpn.macos.NetworkTunnelExtension` (OpenVPN) rather than NordLynx is the relevant extension bundle right now. |
| `vpnSnoozedName` / `vpnSnoozedStart` / `vpnSnoozedUntil` | `"five_min"` / `1786868288` / `0` | A "snooze" (temporary pause/resume) concept exists in prefs — `vpnSnoozedUntil = 0` suggests not currently snoozed. This is the closest thing to a "pause" primitive but it is state read from prefs, not confirmed to be settable via `defaults write` to trigger an actual pause (untested, and even if writable, the app would need to notice the change — no evidence it polls this key).
| `isAppWasConnectedToVPN` | `0` | Tracks last known connection state (informational, likely not authoritative for the running tunnel). |
| `lastConnectionDate` | `"2026-08-16 09:24:19 +0000"` | Timestamp of last connection. |
| `enableCustomDNS` / `customDNS` | `1` / `("103.86.96.100","103.86.99.100")` | Custom DNS is enabled with Nord's own resolvers — directly relevant to this project's DNS-conflict concerns. |
| `threatProtection` | `0` | Threat Protection (separate from the always-active Shield endpoint-security extension) is off. |
| `meshnetEnabled` | `0` | Meshnet off. |
| `startOnBoot` | `0` | Launch-at-login-equivalent flag, off. |
| `postQuantumEnabled` | `0` | Protocol option, off. |

None of these were written to. All are plausible `defaults write` targets in
principle (they are plain preference keys, not derived/computed), but **there
is no evidence the running app polls `com.nordvpn.macos.plist` for live
changes** — Nord apps of this era typically read prefs at launch/settings-open
time only, so a `defaults write` while the app is running may not take effect
until restart. This should be treated as unverified and low-confidence as a
live control surface.

## 4. UI scripting fallback

NordVPN.app **was running** during inspection (`pgrep -fl NordVPN` →
`39228 /Applications/NordVPN.app/Contents/MacOS/NordVPN`). Accessibility
permission for the invoking process was already granted — `osascript`
succeeded with no TCC error on the first call.

Regular application menu bar (`menu bar 1`), read via:
```
osascript -e 'tell application "System Events" to tell process "NordVPN" to get name of every menu bar item of every menu bar'
```
Result: `Apple, NordVPN, Edit, View, Window, Help, missing value`

Menu titles under the `NordVPN` app menu (`menu bar item 2`):
```
osascript -e 'tell application "System Events" to tell process "NordVPN" to get name of every menu item of menu 1 of menu bar item 2 of menu bar 1'
```
Result: `About NordVPN, missing value, Settings..., missing value, Services,
missing value, Hide NordVPN, Hide Others, Show All, missing value, Quit
NordVPN` (the `missing value` entries are menu separators). **No
Connect/Disconnect item here** — this is the standard macOS app menu.
`Edit` menu items were also enumerated for completeness (standard text-editing
items only, not relevant).

Status-bar item (`menu bar 2`, the actual NordVPN menu-bar icon):
```
osascript -e 'tell application "System Events" to tell process "NordVPN" to get properties of menu bar item 1 of menu bar 2'
```
Result:
```
minimum value:missing value, orientation:missing value, position:-4342, 4,
class:menu bar item, accessibility description:missing value,
role description:status menu, focused:false, title:, size:26, 24,
help:missing value, entire contents:, enabled:true, maximum value:missing value,
role:AXMenuBarItem, value:missing value, subrole:AXMenuExtra, selected:false,
name:missing value, description:status menu
```

Attempting to enumerate its menu failed:
```
$ osascript -e 'tell application "System Events" to tell process "NordVPN" to exists menu 1 of menu bar item 1 of menu bar 2'
false

$ osascript -e 'tell application "System Events" to tell process "NordVPN" to get name of every menu item of menu 1 of menu bar item 1 of menu bar 2'
66:70: execution error: System Events got an error: Can't get menu 1 of menu bar item 1 of menu bar 2 of process "NordVPN". Invalid index. (-1719)
```

**No menu items could be enumerated read-only for the status-bar icon.**
`entire contents:` was empty and `exists menu 1 ...` returned `false` — the
menu is not statically present in the accessibility tree; it is very likely
built lazily on click (a common pattern for `NSStatusItem` items backed by a
custom `NSPopover`/`NSView`, consistent with the `MenuBarPopoverView` /
`MenuBarPopoverViewController` / `MenuBarPopoverViewModel` Swift class names
found in `strings` output of `Contents/MacOS/NordVPN`). This means "Connect" /
"Disconnect" menu item titles **cannot be discovered without a click**, which
this task is barred from performing. `qsk.3`, if it must UI-script this
surface, will need to click the status item once to force the popover to
materialize before it can read item titles — that first click is itself an
action this task could not take.

`(no windows)` — `get name of every window` for the NordVPN process returned
empty; the app currently shows no open window (it is running menu-bar-only).

Accessibility permission: **already granted**, no error, no TCC prompt
encountered — nothing to flag for the human to grant.

## 5. Ranking for qsk.3

| Surface | Feasibility verdict | Exact command to try first |
|---|---|---|
| URL scheme (`nordvpn-app://`, `nordvpn-sl://`, `meshnet://`) | **Not viable.** No connect/disconnect/quick-connect/country/server action exists in any binary; every path is a UI deep link (login, MFA, meshnet invite, leak panel, settings navigation, update prompt). Do not build on this surface. | N/A — no candidate command exists to try. |
| `defaults write com.nordvpn.macos <key> <value>` (e.g. `vpnSnoozedUntil`, `isAutoConnectOn`) | **Speculative, low confidence.** Keys exist and look plausible, but no evidence the running app polls prefs live; likely requires app restart to take effect, which defeats a live switcher. Test cheaply before relying on it. | `defaults write com.nordvpn.macos vpnSnoozedUntil -int 0` observed as a no-op read-check first: `defaults read com.nordvpn.macos vpnSnoozedUntil` before/after any hypothetical toggle, and separately confirm via `scutil --nc list` whether tunnel state changed at all. (qsk.3 should test on a value that is trivially reversible, e.g. re-read `killSwitchEnabled` state before touching anything destructive.) |
| UI scripting — status-bar `AXMenuExtra` popover | **Unknown, needs a click to even see menu titles.** Static AX tree is empty (`exists menu 1 ... = false`); item titles for Connect/Disconnect are undiscoverable without opening the popover once. | `osascript -e 'tell application "System Events" to tell process "NordVPN" to click menu bar item 1 of menu bar 2'` then immediately `osascript -e '... get name of UI elements of window 1 of process "NordVPN"'` (or `entire contents of menu bar item 1`) to capture titles, then send `key code 53` (Escape) to close without acting — qsk.3 must decide if a click-to-open-then-escape counts as "action" under its own constraints. |
| UI scripting — app menu (`menu bar 1`) | **Not viable for connect/disconnect.** Confirmed to contain only About/Settings/Services/Hide/Quit — standard app menu, no VPN state items. | N/A |
| Blunt fallback: `osascript -e 'quit app "NordVPN"'` | **Open question, must be tested live.** Quitting the foreground app process does not necessarily tear down the tunnel: the OpenVPN/NordLynx/NordWhisper tunnel extensions run as separate `NEPacketTunnelProvider` app-extension processes (containers seen under `~/Library/Containers/com.nordvpn.macos.{NetworkTunnelExtension,NordLynx,NordWhisperTunnel}`), and `com.nordvpn.macos.helper` runs as a **separate root-owned daemon** (`/Library/PrivilegedHelperTools/com.nordvpn.macos.helper`, PID 39922, independent of the app's PID 39228). Quitting the app is unlikely by itself to disconnect the VPN. **qsk.3 must answer**: does `quit app "NordVPN"` leave the tunnel (and `com.nordvpn.macos.helper`) running? Check with `scutil --nc list` / `ifconfig | grep utun` / `pgrep -fl nordvpn` immediately after quitting. | `osascript -e 'quit app "NordVPN"'` then `pgrep -fl nordvpn` and `ifconfig` to check tunnel/daemon survival — do NOT run this until qsk.3 explicitly authorizes a live test. |
| Blunt fallback: `killall NordVPN` | **Same open question as above, more forceful and less clean (SIGTERM to a GUI app rather than AppleEvent-based quit).** Also does not touch `com.nordvpn.macos.helper` or the tunnel extension processes, which are separate PIDs. | `killall NordVPN` — same caveat, only after qsk.3 explicitly authorizes and only as a last resort behind `quit app`. |

**Bottom line for qsk.3**: the URL-scheme surface is a dead end — do not
pursue it further. The most promising, least invasive first live test is
reading `com.nordvpn.macos` defaults before/after a real connect/disconnect
performed manually (or by the human) to see which keys actually track live
state (a passive observation, not a write). If a write-based toggle is
needed, `vpnSnoozedUntil`/`isAutoConnectOn` are the best candidates but must
be verified to have live effect before being relied on. UI scripting the
status-bar popover is the only surface that can plausibly invoke
Connect/Disconnect directly, but requires an initial click to discover its
contents — flag this as the first thing to test once qsk.3's live-testing
authorization is confirmed. The blunt fallbacks (`quit app` / `killall`) are
last resorts whose main open question — whether the tunnel and
`com.nordvpn.macos.helper` daemon survive app termination — must be
determined empirically by qsk.3, given the process/extension separation
documented in section 2.

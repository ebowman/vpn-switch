# ADR-004: Desired-state reconciliation for VPN Switch

- **Status:** Accepted
- **Date:** 2026-09-08
- **Relates to:** ADR-002 (the IKEv2 switch), ADR-003 (LAN fallback) — this
  ADR does not change either; it adds a new responsibility to VPN Switch
  itself.

## 1. Context

On 2026-09-08 NordVPN was found disconnected without the user having turned
it off. The IKEv2 tunnel (ADR-002) has no kill switch — see
[docs/runbook.md §7](runbook.md#7-tradeoffs-and-known-limitations) "No kill
switch" — so a dropped tunnel fails open and nothing restores it.

Before this change, VPN Switch only *observed* such drops: the poll loop in
`AppModel.pollTick()` (default interval 5 s) notices the state changed and
posts a "changed outside VPN Switch" notification, but nothing reconnects.
This ADR gives the app a new responsibility: the actual VPN state must
match what the user last asked for in VPN Switch, and the app reconnects as
needed to keep it that way.

## 2. Decision

**Persisted per-VPN "keep connected" intent, enforced ON-only through the
existing poll and action queue.**

- **Intent.** Each `VPNTarget` (`nord`, `tailscale`) has a keep-connected
  intent, persisted in `UserDefaults` under the `keepConnectedTargets` key
  (domain `ie.boboco.vpnswitch`) so it survives relaunch and reboot. It is
  set **only** by turning that VPN on inside VPN Switch — the toggle or
  "Turn All VPNs On" — and cleared **only** by turning it off inside VPN
  Switch — the toggle or "Turn All VPNs Off". Nothing outside VPN Switch
  (the CLI, System Settings, the Tailscale menu bar app) changes the
  intent.
- **Enforcement is ON-only.** The reconciler acts only when a target's
  intent is "keep connected" and the observed state is down (`nord`) or
  stopped (`tailscale`). Turning a VPN off inside VPN Switch simply clears
  its intent; the app never forces a VPN *down*. Turning Tailscale back on
  from its own menu, after it was turned off in VPN Switch, is not fought.
- **Trigger and execution.** No new timer. After every poll outcome, the
  reconciler is consulted; if it proposes a reconnect, VPN Switch enqueues
  it through the same serial action queue user clicks already go through,
  so at most one `vpn-ctl.sh` mutation runs at a time and the existing
  pruning/coalescing rules apply unchanged. Waking from sleep resets
  backoff so a drop discovered post-wake reconnects immediately.
- **Backoff and suspension.** A pure `Reconciler` type (no I/O, injected
  clock) tracks per-target attempt state: exponential backoff starting at
  10 s, doubling to a 5-minute cap, reset on success and on wake.
  `vpn-ctl.sh` exit codes map to suspension, which halts reconnect attempts
  for that target until the user acts: exit 2 → "Tailscale needs login",
  exit 3 → "Shortcut missing", exit 4 → "NordVPN app tunnel detected",
  script missing → "vpn-ctl.sh missing". A suspension clears when the user
  toggles that VPN in VPN Switch (off then on) or relaunches the app.
- **UX.** A master "Keep VPNs connected" toggle (default on, persisted)
  pauses enforcement without discarding intent. A kept-on VPN's status line
  gets a " · kept on" suffix. The menu header shows "Reconnecting
  `<name>`… (attempt N)" or "Reconnecting `<name>`… next try in Ns" while
  retrying, and "`<name>` reconnect paused: `<reason>`" while suspended. A
  local notification is posted on a successful reconnect ("`<name>` dropped
  and was reconnected by VPN Switch") and when enforcement suspends ("VPN
  Switch stopped reconnecting `<name>`: `<reason>`").

**Consequence to state plainly:** turning a VPN off in System Settings or
the Tailscale menu — anywhere other than VPN Switch — while VPN Switch is
keeping it on will be reverted within one poll interval (5 s by default)
plus about 3 s to connect. Turn it off in VPN Switch instead.

## 3. Alternatives considered

- **(a) Symmetric enforcement (also force VPNs off).** REJECTED. The
  README documents turning Tailscale off and back on from its own menu bar
  item as supported. Enforcing "off" too would fight that workflow —
  Tailscale coming back up on its own would immediately get switched off
  again by VPN Switch. ON-only enforcement matches what "keep it connected"
  actually means without taking away a documented, independent control
  surface.
- **(b) A launchd watchdog outside the app.** REJECTED. A second process
  watching VPN state and calling `vpn-ctl.sh` independently would need its
  own lifecycle (install, keep-alive, logging) and a second control path
  racing the app's own action queue for the same lock. The app already
  polls and already owns a serial queue; adding reconciliation there is
  strictly less machinery than a second daemon.
- **(c) Rely on the NordVPN app's kill switch instead.** REJECTED. That is
  precisely the configuration ADR-002 moved away from — the app's own
  tunnel collides with Tailscale's `100.64.0.0/10` claim (see
  [ADR-002](adr-002-nordvpn-ikev2.md)). Using it here would reintroduce the
  original DNS black-hole this project exists to avoid.

## 4. Consequences

- VPN Switch now actively changes VPN state on its own, not just in
  response to clicks — reconnect actions run through the same action queue
  and are visible in the menu header and notifications, so they are not
  silent.
- No kill switch is added; a dropped tunnel still fails open for the
  duration of one poll interval plus reconnect time, same as before this
  change — only the automatic recovery is new.
- A user who wants a VPN to stay off permanently, including through app
  restarts, must turn it off *inside* VPN Switch at least once; toggling it
  off elsewhere is expected to be reverted, and that expectation now needs
  documenting everywhere the app's behaviour is described (README, runbook
  §4 and §6).
- Suspension states add four new "stuck" conditions a user can hit
  (Tailscale needs login, Shortcut missing, NordVPN app tunnel detected,
  `vpn-ctl.sh` missing), each requiring a specific fix before enforcement
  resumes — documented in the runbook's troubleshooting table.

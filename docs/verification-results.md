# Verification matrix — IKEv2 era (beads dns-config-c15.6, c15.2, qsk.8)

Date: 2026-08-16. Home LAN (en0 192.0.2.64). Tailscale 1.102.2 standalone.
NordVPN via the IKEv2 profile (`de1545.nordvpn.com`). NordVPN **app** tunnel
never connected during any row below. Judged against ADR-002: with
Tailscale off, tailnet names are *expected* to fail (only `.local` works) —
that row passes if web works and the failure is exactly that.

Columns: `dns-verify` = `bin/dns-verify.sh` summary; `WEB` = HTTPS fetch
(the decisive usability column); names = bare `streamy` / `mac-mini`.

| Row | nord (IKEv2) | tailscale | dns-verify | WEB | bare names | Verdict | Evidence |
|---|---|---|---|---|---|---|---|
| 1 | on | on | 6 passed, 0 failed, 0 skipped | ok(200) | 100.64.10.4 / 100.64.10.65 | **PASS** — the normal state | `snapshots/ts-on-nordikev2-on.txt`; `snapshots/soak-both-up-30min.log`; qsk.10 |
| 2 | on | off | 4 FAIL (names/services), 2 SKIP (staleness) — as designed | ok(200) via Nord | no answer (expected) | **PASS per ADR-002** — internet via Nord, tailnet unavailable | `snapshots/ts-off-nordikev2-on.txt`; `snapshots/qsk8-ts-off.log` |
| 3 | off | on | 6 passed (measured 2026-08-15/16 before IKEv2 was connected; state identical: no Nord tunnel) | ok(200) | 100.64.10.4 / 100.64.10.65 | **PASS** | `snapshots/ts-on-nord-off.txt`; qsk.1 round-trips |
| 4 | off | off | — | — | — | **NOT TESTED** — requires Nord IKEv2 off; gated on the two Shortcuts (or a manual toggle in System Settings > VPN) | — |
| A1 | on | on → off → on | Stopped in 3 s, Running in 2 s via the **installed app's menu**; WEB ok throughout | ok(200) | restored | **PASS** — transitions through the app | `snapshots/qsk8-ts-off.log`, `snapshots/qsk8-ts-on.log` (qsk.8) |
| A2 | on → off / off → on via app | on | — | — | — | **NOT TESTED** — Nord toggle needs the two Shortcuts; app shows the exit-3 message until then (verified) | qsk.5/qsk.6 review |
| E1 | app tunnel present (simulated) | on | collision row FAILs; app shows ⚠︎ App tunnel (unsupported) | — | — | **PASS** — error state detected, no auto-fix | c15.8 override test; qsk.6 review |
| S1 | on | on, 30-min soak @2 s | see soak log | all ok(200) except the deliberate A1 window | — | see `snapshots/soak-both-up-30min.log` (qsk.11) | — |
| — | away (hotspot) rows | | | | | **NOT CAPTURED** — no away network available unattended | — |
| — | sleep / wake | | | | | **NOT TESTED** — cannot be run unattended | — |

## Reading the table

- Rows 1–3 and A1 cover everything a person at home does day to day: both
  on (normal), Tailscale off for a moment, Nord off, and toggling Tailscale
  from the menu bar. All pass, and the one "failure" (row 2's tailnet names)
  is the documented behaviour of not running Tailscale.
- Row 4 and A2 are the only untested combinations, and both are gated on a
  single 30-second human step (create the two Shortcuts) — after which
  `bash bin/vpn-ctl.sh nord off && bash bin/dns-verify.sh` and the app's
  Nord toggle fill them in.
- E1 is the one configuration this whole project exists to prevent (the
  NordVPN app's tunnel alongside Tailscale). It was exercised through the
  detection override rather than by actually connecting the app tunnel,
  because doing so black-holes DNS on the machine and it was unattended.

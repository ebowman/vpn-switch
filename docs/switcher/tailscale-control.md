# Tailscale control: measured behavior

Measurements taken 2026-08-16 on this machine. Tailscale 1.102.2, standalone
install (not App Store / not the macsys system-extension flavor for the CLI
binary path, though the VPN service itself is registered as
`io.tailscale.ipn.macsys`). NordVPN was disconnected throughout (NordVPN.app
process was running but its tunnel interface `utun11` carried no IPv4
address — no active tunnel — for the whole test).

Two CLI binaries exist on this machine:

- `/usr/local/bin/tailscale` — a `sh` wrapper that execs
  `/Applications/Tailscale.app/Contents/MacOS/Tailscale "$@"`. Version
  matches the running `tailscaled` daemon exactly (`1.102.2-t6cac91817-...`).
  **Use this one.**
- `/opt/homebrew/bin/tailscale` (homebrew cask symlink) — same version
  number but a different build (`1.102.2-teb67e5dcb-...`), and every
  invocation prints `Warning: client version "..." != tailscaled server
  version "..."` to stderr. Functionally it worked in testing, but the
  version-mismatch warning is noise `lib/tailscale-ctl.sh` avoids by
  defaulting to `/usr/local/bin/tailscale`.

## Path A: `tailscale down` / `tailscale up`

Ran from a normal user shell, no `sudo`, three round-trips:

| Round | `down` wall-clock | BackendState after `down` | `up` wall-clock | BackendState after `up` |
|-------|-------------------|----------------------------|------------------|--------------------------|
| 1     | 0.54s              | Stopped                    | 0.40s            | Running                  |
| 2     | 0.44s              | Stopped                    | 0.54s            | Running                  |
| 3     | 0.41s              | Stopped                    | 0.39s            | Running                  |

- **No sudo prompt** on any of the 6 calls (3x down, 3x up).
- **No flags needed.** Bare `tailscale up` reconnects using the existing
  node key; `HaveNodeKey: true` persisted across every `down`/`up` cycle, so
  no re-authentication / browser flow was triggered at any point.
- `tailscale down` and `tailscale up` both exited 0 every time.
- By the time each CLI call returned, `tailscale status --json` already
  reported the target `BackendState` — no polling delay was observed on
  this path (see Settle Times below; state, route, DNS resolver, and name
  resolution were all already consistent by t=0 in every repetition).

## Path B: `scutil --nc stop/start "Tailscale 2"`

`scutil --nc list` shows **two** Tailscale entries on this machine:

```
* (Connected)      ECF236BE-E788-40A4-B785-A19078D7E59F VPN (io.tailscale.ipn.macsys) "Tailscale 2"
* (Disconnected)   6C7C9419-60D4-44F2-B96D-31BCE73A8319 VPN (io.tailscale.ipn.macos)  "Tailscale"
```

- **`Tailscale 2`** (bundle id `io.tailscale.ipn.macsys`, UUID
  `ECF236BE-E788-40A4-B785-A19078D7E59F`) is the live one, tied to the
  standalone/system-extension install actually running `tailscaled`.
- **`Tailscale`** (bundle id `io.tailscale.ipn.macos`, UUID
  `6C7C9419-60D4-44F2-B96D-31BCE73A8319`) is stale — it stayed
  `Disconnected` throughout and was never touched.
- **Both entries share the same display name prefix and are easy to
  confuse.** Target by UUID (or bundle id), not by the string
  `"Tailscale 2"` — a future macOS/Tailscale update could reorder or rename
  the visible label, and the UUID is scutil's actual stable key. `lib/
  tailscale-ctl.sh` does not use scutil at all (see below), but if a future
  caller needs to target this service directly, use the UUID
  `ECF236BE-E788-40A4-B785-A19078D7E59F`.

### `scutil --nc stop <uuid>` — reliable

Three repetitions:

| Round | `stop` wall-clock | Settle (route+DNS gone) |
|-------|--------------------|--------------------------|
| 1     | 0.03s              | ≤0s (already gone at first poll) |
| 2     | 0.03s              | ≤0s |
| 3     | 0.03s              | ≤0s |

`scutil --nc stop` returns almost instantly (~30ms, faster than `tailscale
down`'s ~400-540ms) and `tailscale status --json` agreed (`BackendState:
Stopped`) at every check.

### `scutil --nc start <uuid>` — **UNRELIABLE, do not use**

This is the key finding of this task. After stopping via `scutil --nc stop`,
calling `scutil --nc start <uuid>` returned in ~0.03-0.06s and immediately
made `scutil --nc status <uuid>` report **`Connected`** — but the actual
`tailscaled` backend stayed **`Stopped`** (per `tailscale status --json`),
with no `100.64/10` route and no `100.100.100.100` resolver entry, for the
entire observation window (polled every 0.5s for 15+ seconds with zero
progress; one earlier attempt was left for the ~2s between checks in a
different run and was still wrong afterward). `scutil --nc status` and
`tailscale status --json` **disagreed for the whole window**: scutil's view
of the "connection" (i.e., the NetworkExtension session/config) came up, but
tailscaled's own backend state machine did not follow. Recovery required
falling back to `tailscale up`, which worked immediately (~0.44-1.17s,
verified BackendState: Running, route and DNS restored, `streamy` resolved
to `100.64.10.4`).

Because of this, `scutil --nc start` cannot be trusted to bring Tailscale up
from a stopped state. `lib/tailscale-ctl.sh`'s `ts_up` calls `tailscale up`
exclusively, never `scutil --nc start`. `ts_down` also calls `tailscale
down` exclusively (not `scutil --nc stop`) for symmetry and because
`tailscale down`/`up` is the only path proven reliable in both directions —
mixing control surfaces (stop via scutil, start via CLI) is unnecessary
complexity given `tailscale down` is not meaningfully slower than `scutil
--nc stop` (worst case observed: 0.54s vs 0.03s, both well under any
reasonable timeout).

### Do Path A and Path B leave the same end state?

When both sides actually agree (i.e., using `scutil --nc stop`, or after
recovering with `tailscale up`), yes: `tailscale status --json`
`BackendState`, the `100.64/10` route, the `100.100.100.100` DNS resolver
entry, and `dscacheutil` resolution of `streamy` to `100.64.10.4` were all
consistent with each other. The Tailscale menu bar icon was not
independently screenshotted during this test but tracks the same
`tailscaled` backend that `tailscale status` reads, so it is expected to
follow `BackendState` in all cases — including the broken `scutil --nc
start` case, where the icon would be expected to show "not connected" while
`scutil --nc status` claims Connected. This was not directly verified
against the icon and is noted as an assumption, not a measured fact.

**The one case where the two paths clearly diverge is `scutil --nc start`**:
scutil's own status and tailscaled's actual backend state disagree, and only
tailscaled's state (route, DNS, resolution) reflects reality.

## State detection

`tailscale status --json` → `.BackendState`. Observed values:

- **`Running`** — confirmed, connected and passing traffic (route present,
  DNS resolver present, `streamy` resolves to its Tailscale IP).
- **`Stopped`** — confirmed, both via `tailscale down` and via `scutil --nc
  stop`. No route, no `100.100.100.100` resolver entry.
- **`NeedsLogin`** — **not induced** (explicitly out of scope for this task
  per the edge-case constraint: "If 'up' returns NeedsLogin, record it and
  stop — do not attempt to log in"). It was not observed in any of the 6
  Path-A round-trips or 3 Path-B round-trips; `HaveNodeKey` stayed `true`
  throughout, so re-authentication was never triggered. Documented from the
  `tailscale up --help` description ("logging in if needed") and general
  Tailscale CLI behavior: when a node's key has expired or been revoked,
  `tailscale up` exits 0 but leaves `BackendState: NeedsLogin` and populates
  `AuthURL` with a login link, rather than reconnecting. A caller must
  check `ts_state` after `ts_up` rather than trust the CLI's exit code, and
  must **not** attempt to open `AuthURL` automatically — that is a
  human-driven step.
- **`Starting`** — **not induced/observed**. In all 9 round-trips the
  backend was already at the target state by the time the CLI call
  returned (see Settle Times), so no transient `Starting` value was ever
  captured mid-poll. It is documented in Tailscale's state machine as the
  transient value between `Stopped`/`NeedsLogin` and `Running` while the
  daemon is establishing the tunnel; `ts_wait_for` will simply keep polling
  through it if it is ever observed in practice (e.g. on a slower network
  or a coordination-server round trip), since it treats any state other
  than the target as "not yet".

## Settle times

Settle is defined as: **(a)** the `100.64/10` route disappears from
`netstat -rn -f inet` (down) or reappears (up); **(b)** `scutil --dns` no
longer lists `100.100.100.100` (down) or lists it again (up); **(c)**, for
`up` only, `dscacheutil -q host -a name streamy` returns `100.64.10.4`.
Polled at 0.5s granularity (later re-verified at 0.2-0.3s granularity for
the fast scutil-stop path).

| Transition | Trigger | Settle time observed (route+DNS[+resolve]) |
|---|---|---|
| down | `tailscale down` | ≤0s after the call returns, in all 3 rounds (already settled by first poll) |
| up | `tailscale up` | ≤0s after the call returns, in all 3 rounds (route, DNS, and `streamy` resolution all already correct by first poll) |
| down | `scutil --nc stop <uuid>` | ≤0s after the call returns, in all 3 rounds |
| up | `scutil --nc start <uuid>` | **never settled** — route/DNS did not return even after 15s of polling; not a usable path |

**Practical implication for the switcher's waits:** for both `tailscale
down` and `tailscale up` (and `scutil --nc stop`), the CLI call itself is
synchronous with the backend state change on this machine — there is no
meaningful additional settle delay to wait out beyond the call's own
wall-clock time (worst case observed: 0.54s for `down`, 0.56s for `up`).
`lib/tailscale-ctl.sh`'s `ts_wait_for` still polls (at 0.5s intervals)
rather than assuming instant settle, both because this is only 9 samples on
one machine/network and because `ts_up` can legitimately take longer if
`NeedsLogin`/`Starting` is ever hit (e.g., coordination server latency,
node-key rotation) — the timeout parameter exists precisely to bound that
uncertain case, defaulting to a generous window (30s was used in this
task's verification) rather than the sub-second figures measured here.

## Sudo / privilege summary

No `sudo` was needed anywhere in this task: not for `tailscale up`, not for
`tailscale down`, not for `scutil --nc stop`, not for `scutil --nc start`
(even though that path didn't work correctly, it did not fail on
permissions — it failed by silently not reconnecting the backend).

## `lib/tailscale-ctl.sh` summary

Defines `ts_up`, `ts_down`, `ts_state`, `ts_wait_for <state>
<timeout_seconds>`, sourceable with no side effects. `ts_up`/`ts_down` both
drive `/usr/local/bin/tailscale` (override via `TS_CTL_BIN`) exclusively,
per the `scutil --nc start` unreliability finding above. Every external
call is wrapped with `timeout`/`gtimeout` when available. See the file's
header comment for exit-code contracts.

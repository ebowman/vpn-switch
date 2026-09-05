# tests/

Shell-level tests for the bash libraries and scripts under `lib/` and `bin/`.

- `vpn-run-bounded-test.sh` — exercises `_vpn_run_bounded` (the shared
  pure-shell bounded runner in `lib/tailscale-ctl.sh` / `lib/nord-ctl.sh`):
  prompt return under `$(...)` capture, `124` on timeout, exit-status
  preservation, no stray child processes, and no leftover flag files. Its
  self-check (case 1a) proves the suite can actually catch the regression
  by sed-deriving a broken copy of the real lib (stripping the watchdog's
  `>/dev/null 2>&1` redirect) into a scratch dir and confirming that copy
  hangs; point it at an already-broken lib via `VPN_RUN_BOUNDED_LIB=...`
  to see the whole suite fail instead.
- `nord-ikev2-profile-test.sh` — exercises `bin/nord-ikev2-profile.sh`'s
  envfile handling (ownership/mode/symlink checks, KEY=VALUE parsing,
  validation) and determinism.

Run either directly:

```bash
bash tests/vpn-run-bounded-test.sh
bash tests/nord-ikev2-profile-test.sh
```

Each prints PASS/FAIL per case and exits non-zero if any case fails. Both
run entirely against scratch state (a temporary `HOME`, background
`/bin/sleep`/`/bin/echo`/`/bin/true` subprocesses, etc.) and never touch
real VPN/DNS state, network connections, or credentials.

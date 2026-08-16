# LAN DNS (home.arpa) — ADR-003 option C, refined design

What: bare hostnames (`streamy`, `mac-mini`) resolve to the right
address in every network state this user hits routinely: Tailscale up
(tailnet IP), Tailscale down at home (LAN IP) — including with the NordVPN
IKEv2 profile up, which earlier broke search-domain expansion entirely (see
"How it works" below).
Decision and rationale: [docs/adr-003-lan-fallback.md](../adr-003-lan-fallback.md)
and `dns-config-j9y.3`'s comment thread ("ROOT-STEP RESULT AND A NEW,
DECISIVE FINDING" / "REFINED DESIGN").

## How it works

Three pieces, each solving a different part of the problem:

1. **Search-suffix expansion** — turning bare `streamy` into
   `streamy.home.arpa` in the first place. macOS only expands unqualified
   names using the **primary** network service's search domains (plus
   NetworkExtension supplemental-match domains, which is how Tailscale's own
   suffix always applies regardless of who is primary). Two sources feed
   `home.arpa` into that list depending on which service is primary:
   - **Wi-Fi's own search list** (`home.arpa`, added by a one-time root step)
     — applies when Wi-Fi (`en0`) is primary, i.e. Nord IKEv2 is down.
   - **The NordVPN IKEv2 profile's `DNS.SearchDomains` key**
     (`bin/nord-ikev2-profile.sh`, `dns-config-j9y.3` R1) — applies when the
     Nord IKEv2 tunnel is primary, which is exactly when Wi-Fi's list becomes
     inert (measured: `State:/Network/Global/DNS` showed only Tailscale's
     suffix while `ipsec0` was primary, never Wi-Fi's `home.arpa`). See
     `docs/switcher/nord-ikev2-setup.md`'s "DNS search-domain dict" section
     for the exact keys and how to disable it.
   Tailscale's own suffix (`tailXXXX.ts.net`) is tried first while
   Tailscale runs (a NetworkExtension supplemental-match domain, always
   present regardless of primary), so tailnet answers keep winning while
   Tailscale is up.
2. **Routing** — once a query is `streamy.home.arpa`, `/etc/resolver/home.arpa`
   (a one-time root step: `nameserver 127.0.0.1`, `port 5354`) sends it to
   the local dnsmasq resolver below instead of the normal DNS path.
3. **Answering the right address for the current state** — dnsmasq, a
   **user** LaunchAgent bound to `127.0.0.1:5354`, authoritative for
   `home.arpa`, answers each `<name>.home.arpa` from a generated hosts file
   (`~/Library/Application Support/vpn-switch/home-arpa.hosts`) that
   `lib/lan-dns.sh`'s `lan_dns_render` re-writes and SIGHUPs dnsmasq to
   re-read **every time Tailscale toggles**:
   - Tailscale up → each host's **live** tailnet IP, read from
     `tailscale status --json` (falling back to `config/lan-hosts.conf`'s
     tailnet column if the peer is offline/absent).
   - Tailscale down → each host's LAN IP, from `config/lan-hosts.conf`.

   `bin/vpn-ctl.sh tailscale on|off` calls this automatically after the
   transition settles (before the web check). `bin/vpn-ctl.sh lan-dns sync`
   exists standalone for other callers that observe a Tailscale change some
   other way (the VPN Switch app's poll loop does not yet call this — see
   `dns-config-qsk.12`, filed as follow-up work, not done in this bead).

   The rendered hosts file is **FQDN-only** (`<ip> <name>.home.arpa`, no
   bare `<name>` second column) — a bare-name column was measured to leak:
   dnsmasq answers it for *any* unqualified query regardless of the querying
   domain, not just within the `home.arpa` zone. Omitting it and relying on
   dnsmasq's own `domain-needed` directive was verified instead: a bare
   query then correctly gets `NXDOMAIN`, and `streamy.home.arpa` still
   resolves via the FQDN line.

## One-time setup (root steps + profile reinstall)

1. Run the installer (no sudo; installs dnsmasq + the LaunchAgent, renders
   the initial hosts file from current Tailscale state):

   ```
   bin/lan-dns-install.sh
   ```

2. It prints two commands for a human to run — apply them once:

   ```
   sudo mkdir -p /etc/resolver && printf 'nameserver 127.0.0.1\nport 5354\n' | sudo tee /etc/resolver/home.arpa
   sudo networksetup -setsearchdomains "Wi-Fi" <existing search domains…> home.arpa
   ```

   The exact second command (service name and existing domain list) is
   printed by the script for each active network service that has an IP —
   copy it verbatim rather than retyping it, since the existing domain list
   varies by machine.

3. **If you use the NordVPN IKEv2 profile**, regenerate and reinstall it so
   its `DNS.SearchDomains` key is present (needed for bare names to expand
   while Nord IKEv2 is primary — see "How it works" above):

   ```
   NORD_IKEV2_ENVFILE=/path/to/creds.env bash bin/nord-ikev2-profile.sh
   ```

   Then reinstall via **System Settings > Profiles** (fixed `PayloadUUID`s
   mean this replaces the existing profile, not a duplicate). See
   `docs/switcher/nord-ikev2-setup.md` for the full runbook. This may
   briefly drop the IKEv2 tunnel while it reloads.

Re-running `bin/lan-dns-install.sh` is safe (idempotent): it regenerates
dnsmasq's config from `config/lan-hosts.conf`, reloads the LaunchAgent,
re-renders and re-syncs the hosts file against current Tailscale state, and
detects whether the two root steps are already applied — quiet if so.

## Verify

```
scutil --dns | grep -A3 home.arpa
dscacheutil -q host -a name streamy.home.arpa   # FQDN, any state (routing)
dscacheutil -q host -a name streamy             # bare name (needs the search
                                                 # suffix from step 2/3 above)
bin/vpn-ctl.sh lan-dns status                   # answering/not-answering/not-installed
bin/dns-verify.sh                                # full state-aware check, incl. staleness
```

`bin/dns-verify.sh` and `bin/vpn-ctl.sh status` both report a `lan-dns=`
token (`answering` / `not-answering` / `not-installed`), via
`lib/lan-dns.sh`'s `lan_dns_status` — reflecting whether the dnsmasq
LaunchAgent itself is up and responding, independent of whether the search
suffix / routing steps above are in place.

`bin/dns-verify.sh`'s staleness check compares the resolved bare-name
address against whichever table applies to the **current** Tailscale
state — live `tailscale status` output when up, `config/lan-hosts.conf`'s
LAN column when down — and reports "matches live Tailscale IP" /
"matches LAN table" accordingly.

## Add a host

1. Edit `config/lan-hosts.conf`, adding a line:
   `<name> <lan-ip> <tailnet-ip>`.
2. Re-run `bin/lan-dns-install.sh` (regenerates dnsmasq's config and the
   hosts file, reloads the LaunchAgent; the root steps and the Nord profile
   reinstall do not need to be repeated).

## Undo

```
bin/lan-dns-uninstall.sh
```

Removes the LaunchAgent, generated dnsmasq config/logs, the rendered hosts
file, and the pid-file (no sudo). It prints the matching root-level undo
(`sudo rm /etc/resolver/home.arpa` and the `networksetup -setsearchdomains`
command with `home.arpa` removed from the list) and an optional
`brew uninstall dnsmasq` — neither is run for you. If you also want to
remove the `DNS.SearchDomains` key from the NordVPN IKEv2 profile, regenerate
it with `NORD_IKEV2_SEARCH_DOMAINS=""` and reinstall (see
`docs/switcher/nord-ikev2-setup.md`).

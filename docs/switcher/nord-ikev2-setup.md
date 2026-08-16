# NordVPN IKEv2 profile: setup, install, and removal (human runbook)

This is the human-operated runbook for `dns-config-qsk.9`'s output:
`bin/nord-ikev2-profile.sh`. That script only generates a `.mobileconfig`
file; it never installs anything. Installing and removing the profile are
manual steps you perform yourself, described below.

Display name used throughout: **`NordVPN IKEv2`** — this is the exact
`UserDefinedName` baked into the generated profile, and is what will appear
in System Settings > VPN and in Shortcuts. (It does **not** appear in
`scutil --nc list`, even while connected — see "5. Verify".)

## Why this exists

NordVPN's app cannot be scripted for switching (see `qsk.2`): no working URL
actions, a lazily-built popover, a root helper, and an always-on kill switch.
NordVPN's manually-configured IKEv2/IPsec service (documented in NordVPN
support article 19921536696977) is a native macOS VPN configuration instead:
it shows up in System Settings > VPN and in the Shortcuts "Set VPN" action,
and — the decisive property — its DNS is pushed by Nord's server
(`103.86.96.100`/`103.86.99.100`), not installed by the app at `100.64.0.2`,
so it does not collide with Tailscale (see ADR-002). It is controlled via
Shortcuts (section below), **not** `scutil --nc`: a profile-installed VPN
config lives in NetworkExtension's store and `scutil --nc` cannot address it
by name or by any UUID (verified 2026-08-16, `dns-config-qsk.10`).

## 1. Get the IKEv2 server hostname

1. Sign in at [Nord Account](https://my.nordaccount.com/).
2. Go to **Advanced settings** (or **Set up NordVPN manually**, wording may
   vary by account UI version).
3. Choose **Server recommendation**, then select **IKEv2/IPSec**.
4. Copy the hostname it gives you (e.g. `us1234.nordvpn.com`). This
   identifies **one specific server**, not "NordVPN" in general — see
   "What you lose" below for what that means.

## 2. Get service credentials

1. In Nord Account, find **Service credentials** (sometimes under
   "Manual setup" or a similar section).
2. Generate/reveal a service username and password.
3. **Use these, not your NordVPN account login email/password.** Service
   credentials are separate, scoped, revocable credentials meant exactly for
   manual protocol configs like this one.

## 3. Run the generator

The generator never accepts secrets as command-line arguments (they would
leak into `ps` for any user on the machine). Supply them via environment
variables or a mode-600 file.

Directly via environment variables:

```bash
NORD_IKEV2_SERVER=us1234.nordvpn.com \
NORD_IKEV2_USER='<service-username>' \
NORD_IKEV2_PASS='<service-password>' \
bash bin/nord-ikev2-profile.sh
```

Or via a credentials file (recommended if you don't want the password
sitting in shell history):

```bash
cat > /tmp/nord-creds.env <<'EOF'
NORD_IKEV2_SERVER=us1234.nordvpn.com
NORD_IKEV2_USER=<service-username>
NORD_IKEV2_PASS=<service-password>
EOF
chmod 600 /tmp/nord-creds.env
NORD_IKEV2_ENVFILE=/tmp/nord-creds.env bash bin/nord-ikev2-profile.sh
rm /tmp/nord-creds.env
```

The generator refuses to source `NORD_IKEV2_ENVFILE` unless it is mode 600,
and refuses to write its output anywhere inside this repo.

Default output location:
`$HOME/Library/Application Support/vpn-switch/NordVPN-IKEv2.mobileconfig`
(mode 600). Override with `NORD_IKEV2_OUT` if needed.

**The output file contains your NordVPN service password in plaintext.**
Apple's Configuration Profile format has no field-level encryption for
`AuthPassword`. The generator sets file mode 600 and prints a warning; treat
the `.mobileconfig` file itself as a credential. Do not copy it into this
repo, attach it to tickets, or otherwise share it.

Re-running the generator (e.g. after rotating the service password, or to
point at a different server) **replaces** an already-installed profile
rather than creating a duplicate, because the script uses fixed
`PayloadUUID`s. Just regenerate and reinstall (step 4).

## 4. Install the profile

The generator does not do this step — you do it manually:

1. In Finder, locate the generated file (default path above) and
   double-click it, or run `open "$HOME/Library/Application Support/vpn-switch/NordVPN-IKEv2.mobileconfig"`.
2. This opens **System Settings > Privacy & Security > Profiles** (or
   prompts you to go there). Recent macOS versions require you to
   explicitly review and approve a downloaded profile here — it will not
   install silently. Follow the on-screen review/approve flow.
3. You will be asked to confirm installation, and may be prompted for your
   Mac login password since installing a VPN configuration profile is a
   privileged operation.

## 5. Verify

```bash
profiles list            # expect: profileIdentifier: ie.boboco.vpn-switch.nordvpn-ikev2
```

Then open **System Settings > VPN**: `NordVPN IKEv2` is listed with a
toggle. The profile installs it **disabled/disconnected**; the toggle is
the connect switch. Flip it on once here to confirm it connects, then check:

```bash
ifconfig ipsec0 | grep inet          # a 10.x tunnel address, e.g. 10.6.0.41
scutil --dns | grep -A2 'resolver #1' # nameserver 103.86.96.100 / 103.86.99.100
```

Note what you will **not** see: `scutil --nc list` does not show this
config — not by name, not by UUID, not even while connected. That is
expected (NetworkExtension store, not SystemConfiguration), and it is why
programmatic control goes through Shortcuts (next sections), and why
`bin/dns-verify.sh` and friends detect Nord IKEv2 by the `ipsec0` interface
and the `103.86.x` resolvers rather than by any service name.

## 6. Remove the profile

Via System Settings:

1. **System Settings > Privacy & Security > Profiles**.
2. Select the `NordVPN IKEv2` profile.
3. Click the remove/delete control (a `-` button or "Remove Profile"),
   and confirm. You may be prompted for your Mac login password.

Via command line:

```bash
profiles list                     # find the identifier, e.g. ie.boboco.vpn-switch.nordvpn-ikev2
profiles remove -identifier ie.boboco.vpn-switch.nordvpn-ikev2
```

(`profiles remove` may require `sudo` depending on how the profile was
installed; if so, run it interactively yourself — do not script sudo into
this pipeline.)

## Shortcuts for NordVPN control

`bin/vpn-ctl.sh` and `lib/nord-ctl.sh` control the `NordVPN IKEv2` profile
through two Shortcuts you create once, by hand — there is no CLI or
`profiles` handle for a profile-installed VPN on this macOS (see
`dns-config-qsk.10`'s control-handle investigation for the dead ends:
`scutil --nc` cannot address it, `profiles install` is removed, and System
Settings > VPN is not UI-scriptable). Until both shortcuts exist,
`vpn-ctl.sh nord on` / `nord off` exit **3** with a message pointing back
here.

1. Open **Shortcuts.app**.
2. Click **+** to create a new shortcut.
3. Search the action library for **"Set VPN"** and add it.
4. In the action, set **VPN** to **`NordVPN IKEv2`** (the profile installed
   earlier in this document) and **Mode** to **Connect**.
5. Rename the shortcut (click its name at the top) to **exactly**
   `NordVPN On` — no extra punctuation, no trailing space. The scripts
   match this name literally.
6. Repeat steps 2-4 for a second shortcut, this time with **Mode** set to
   **Disconnect**, named **exactly** `NordVPN Off`.
7. **Do not use Mode "Toggle"** for either shortcut — `nord_connect` and
   `nord_disconnect` each need a one-directional, idempotent action; a
   toggle would flip the tunnel the wrong way whenever it is invoked while
   already in the target state.

Confirm both were created correctly:

```bash
shortcuts list | grep -i nordvpn
```

This should print exactly:

```
NordVPN On
NordVPN Off
```

Once both exist, `vpn-ctl.sh nord on` / `nord off` work immediately with no
code change — the library invokes `shortcuts run "NordVPN On"` /
`shortcuts run "NordVPN Off"` and then verifies the result against reality
(the `ipsec0` interface and the `103.86.x` resolvers), never trusting the
`shortcuts run` exit code — it reports success (exit 0) even when the named
shortcut does not exist at all, which is exactly the case `vpn-ctl.sh`'s
exit-3 check exists to catch before ever invoking anything.

## What you lose compared to the NordVPN app

This manual IKEv2 profile is a plain OS-level IPsec/IKEv2 tunnel to **one
specific NordVPN server**. Using it instead of the app means giving up:

- **NordLynx speed** — NordLynx is Nord's WireGuard-based protocol; IKEv2 is
  typically slower.
- **Threat Protection** — the app's DNS-based malware/ad/tracker blocking is
  not present in a bare IKEv2 tunnel.
- **Kill switch** — the app can block all traffic if the VPN drops; this
  profile has no equivalent (and deliberately does **not** set
  `IncludeAllNetworks`, which is the closest analogous key, precisely to
  avoid recreating kill-switch-like lockout behavior for this use case).
- **Auto server selection / load balancing** — the app picks a good server
  dynamically; this profile pins to the **one hostname** you fetched in
  step 1. If that server gets slow, overloaded, or decommissioned, you must
  go back to Nord Account, get a fresh recommended hostname, and regenerate
  the profile (step 3) to rotate — the fixed `PayloadUUID`s mean the
  reinstalled profile replaces the old one rather than piling up duplicates.

## Reference: what the generated profile does and does not do

- `VPNType`: `IKEv2`, `UserDefinedName`: `NordVPN IKEv2`.
- `IKEv2.RemoteAddress` / `IKEv2.RemoteIdentifier`: the server hostname from
  step 1.
- `IKEv2.LocalIdentifier`: the service username. Apple marks this key
  required. In EAP-only mode it is just the IKE identity string and is not
  what authenticates you (the EAP exchange with `AuthName`/`AuthPassword`
  is) — using the username here matches NordVPN's own manual instructions.
- `IKEv2.AuthenticationMethod`: `None` with `IKEv2.ExtendedAuthEnabled`: `1`
  — this is Apple's documented way to select EAP-only (username/password)
  authentication instead of a shared secret or certificate.
- `IKEv2.AuthName` / `IKEv2.AuthPassword`: the service credentials from
  step 2.
- `IKEv2.OnDemandEnabled`: `0` (off) — **required**. Auto-connect on-demand
  would recreate the always-reconnecting behavior that made the NordVPN app
  unsuitable for scripted switching in the first place (`qsk.2`).
- A `com.apple.security.root` payload embeds NordVPN's IKEv2 root CA
  (`config/nord-ikev2/nordvpn-root.der`) so the tunnel's server certificate
  chain validates without a separate manual Keychain-trust step.
- **No DNS override keys are set.** This is intentional: `qsk.3c` needs to
  observe whatever resolver Nord's IKEv2 server actually pushes, unmodified
  by this profile.
- **No `IncludeAllNetworks`, no `OnDemandRules`.**

## Certificate provenance

The embedded root CA (`config/nord-ikev2/nordvpn-root.der`) was fetched
2026-08-16 from `https://downloads.nordcdn.com/certificates/root.der`, the
exact URL linked as "NordVPN IKEv2 certificate" by NordVPN support article
19921536696977
(<https://support.nordvpn.com/hc/en-us/articles/19921536696977-How-to-connect-to-NordVPN-with-IKEv2-IPSec-on-macOS>).

Verified with:

```
openssl x509 -inform der -in config/nord-ikev2/nordvpn-root.der -noout -subject -issuer -dates -fingerprint -sha256
```

```
subject=C = PA, O = NordVPN, CN = NordVPN Root CA
issuer=C = PA, O = NordVPN, CN = NordVPN Root CA
notBefore=Jan  1 00:00:00 2016 GMT
notAfter=Dec 31 23:59:59 2035 GMT
sha256 Fingerprint=8B:5A:49:5D:B4:98:A6:C2:C8:CA:7A:F6:AE:4A:5C:DF:65:E6:89:D0:6C:BE:CC:B0:24:53:C9:1C:31:91:E2:FF
```

Self-signed (subject == issuer), consistent with a root CA. Not expired
(valid through end of 2035 at the time this was fetched).

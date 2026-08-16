# NordVPN support request

Draft for submission via NordVPN support. Plain text below the line — paste it as-is.

---

**Subject:** macOS client publishes DNS resolver 100.64.0.2, which collides with Tailscale's CGNAT range and breaks all DNS

Hello,

I'm hitting a reproducible conflict between the NordVPN macOS client and Tailscale, and I've traced it to a specific address choice in your client. I've done fairly detailed diagnosis, so I'll lead with the finding.

**Summary:** the macOS client installs `100.64.0.2` as the system DNS resolver. That address is inside `100.64.0.0/10` (RFC 6598 shared address space), which Tailscale claims and routes in its entirety. When both are running, queries to your resolver are routed into the Tailscale interface instead of the NordVPN tunnel and are silently dropped. Because NordVPN's resolver is installed as the primary one, *all* DNS on the machine fails and the computer appears to have no network connection.

**Environment**

- macOS (Darwin 25.5.0), Apple Silicon
- NordVPN macOS app, connected over the standard tunnel (`utun`, tunnel address 10.5.0.2)
- Tailscale 1.102.2 (standalone build)

**Evidence — the same address, with only Tailscale changing**

With Tailscale **off**:

```
route -n get 100.64.0.2      ->  gateway: 10.5.0.2, interface: utun11   (your tunnel)
dig @100.64.0.2 apple.com A  ->  17.253.144.10                          (answers immediately)
```

With Tailscale **on**:

```
route -n get 100.64.0.2      ->  interface: utun19                      (Tailscale)
dig @100.64.0.2 apple.com A  ->  ";; connection timed out; no servers could be reached"
```

Nothing about NordVPN changed between those two measurements. The only variable is whether Tailscale is running and claiming `100.64.0.0/10`.

For contrast, a resolver outside that range answers normally in both states, which is what points at the address rather than at the tunnel:

```
dig @100.100.100.100 <hostname>  ->  answers correctly, Tailscale on or off
```

**Why this is difficult to work around**

- `100.64.0.2` does not appear in your published documentation. Your documented DNS servers are `103.86.96.100` and `103.86.99.100`, neither of which is in CGNAT space.
- Setting a custom DNS server in the app (I tried `1.1.1.1`) does **not** change this. After the change and a full reconnect, `scutil --dns` still shows `100.64.0.2` as the nameserver and `1.1.1.1` appears nowhere. The setting appears to select the upstream your resolver forwards to, not the address the client publishes to macOS.
- Split tunnelling is not available on macOS, so I can't exclude the range that way. The Linux client's subnet allowlist would address this, but there's no macOS equivalent.
- Tailscale doesn't expose a way to narrow its claimed range — it requires the full `/10` to operate.

**Questions**

1. Is there any supported way to make the macOS client publish a resolver address outside `100.64.0.0/10`?
2. Is the use of `100.64.0.2` intentional and documented anywhere? If it's related to Meshnet, is there a way to disable that component so the address isn't installed?
3. Are there plans to move the client's resolver out of RFC 6598 space? Tailscale is widely deployed and claims that entire range, so any customer running both products on macOS will hit this.

I'm not looking for general troubleshooting steps — DNS, routing and the tunnel are all healthy in isolation, and I've verified the failure is specific to this address being inside a range another VPN legitimately claims. What I need is either a way to change the published resolver address, or confirmation that it isn't currently possible.

Happy to provide packet captures, `scutil --dns` output, or timestamped logs of the transition if useful.

Thanks,
Eric

---

## Notes for the sender (not part of the message)

- **Tone is deliberately factual, not annoyed.** First-line support handles volume; a clear reproduction with a specific ask is far more likely to get escalated than a complaint.
- **The two `dig` results are the entire argument.** If the reply is a generic "reinstall the app / try another server" script, reply by quoting just those four lines and asking again for escalation.
- **Question 2 matters most in practice.** If `100.64.0.2` is a Meshnet component, disabling Meshnet may be a real fix and is the cheapest possible outcome.
- **Don't accept "use a different DNS in the app" as an answer** — that was tested and refuted; the setting changes the upstream, not the published address.
- Interface names (`utun11`, `utun19`) drift between sessions on macOS. If you re-run anything before sending, the numbers may differ; the behaviour won't.
- Supporting evidence lives in `docs/research/`, `snapshots/`, and the `dns-config-4ev` bead if they ask for more.

# Self-hosted Tailscale replacement: plan

Status: **configuration drafted, not deployed or tested**. The files in this directory (see [Drafted configuration](#drafted-configuration)) have not been run. This document does not record a deployed server or client migration.

## Goal

Connect several Windows and Linux machines in one private network using a coordination server under our control. Allow the machines to reach each other according to a policy, with SSH where needed. Keep any existing access path working until the new network has been tested.

## Architecture

| Part | Choice | Purpose |
|---|---|---|
| Coordination server | [Headscale](https://headscale.net/stable/about/features/) on one always-on Linux VM | Device registration, peer discovery, policy, and MagicDNS |
| Client on each machine | Official Tailscale app for [Windows](https://headscale.net/stable/usage/connect/windows/) or [Linux](https://headscale.net/stable/usage/getting-started/), pointed at Headscale | Encrypted connections between machines |
| Public endpoint | DNS name with HTTPS on TCP 443 | Lets clients reach Headscale from different networks |
| Fallback relay | Headscale's embedded DERP, Tailscale's public DERP servers, or both | Carries encrypted client traffic when a direct connection cannot be made |
| SSH policy, if needed | Allow only the intended users and machines | Controls SSH access through the private network |

Headscale replaces Tailscale's hosted **coordination server**, not its client apps. [Headscale supports Windows and Linux Tailscale clients](https://headscale.net/stable/about/clients/). Each machine that joins the network needs the client installed; it does not need its own coordinator VM.

### Where client traffic goes

Clients normally exchange data **directly with each other**. Headscale helps them find each other but does not carry their normal data traffic. DERP handles small discovery messages and carries the encrypted data only when a direct connection fails. Thus, running Headscale does **not** mean all traffic between all clients passes through the server. A connection can start via DERP and move to a direct path. Use `tailscale status` or `tailscale ping <machine>` to check whether a connection is `direct` or `relay`. See [Tailscale connection types](https://tailscale.com/docs/reference/connection-types) and [DERP servers](https://tailscale.com/docs/reference/derp-servers).

If the embedded DERP on our VM relays a 100 GB transfer, the VM receives about 100 GB and sends about 100 GB, plus overhead. The provider may count only outbound traffic or both directions toward its monthly transfer allowance. Direct transfers do not consume the VM's data transfer allowance. Multiple relayed connections share the VM's network speed. If clients use a public DERP server instead, that relayed data does not pass through our VM. [Headscale's embedded DERP is disabled by default](https://headscale.net/stable/ref/derp/); enabling it can add it alongside public DERP servers, or the public DERP map can be removed for fully self-hosted relaying. Using only one self-hosted DERP makes that relay a single point of failure.

## How many VMs and what size?

For several **existing** machines, provision **one new VM** for Headscale. The Windows and Linux machines remain clients. If all client machines are also being created as VMs, the total is **one coordinator VM plus one VM per client machine**. No separate DERP VM is required when using Headscale's embedded DERP.

| Resource | Practical starting point for a small network |
|---|---|
| CPU | 1 vCPU |
| Memory | 1 GB RAM |
| Disk | 10–20 GB, with backups stored elsewhere |
| OS | Debian 12+ or Ubuntu 22.04+ for Headscale's [official packages](https://headscale.net/stable/setup/install/official/) |
| Network | Public IP; stable DNS name; enough network speed and monthly transfer for expected **relayed** traffic |

These CPU, RAM, and disk values are planning estimates, **not official Headscale minimum requirements**. Increase capacity if the network grows, clients change networks frequently, or many connections use the embedded relay. Headscale's [scaling FAQ](https://headscale.net/stable/about/faq/) says frequent device changes and large networks increase coordinator CPU work. Relay usage can make the VM's network speed or transfer allowance the more important limit. Multiple relayed transfers share the VM's connection capacity; exceeding a monthly transfer allowance can incur extra charges or throttling, depending on the provider.

## Requirements before deployment

1. An always-on Linux VM with a public IP. A public IPv4 address is sufficient; [Headscale recommends dual-stack IPv4 and IPv6](https://headscale.net/stable/setup/requirements/).
2. A domain or subdomain, such as `headscale.example.com`, pointed at the VM, plus a valid HTTPS certificate.
3. Public inbound TCP 443. TCP 80 is needed when using HTTP-01 certificate issuance or HTTP redirects. If the embedded DERP is enabled, also allow UDP 3478 for STUN. Keep metrics and administration private. See [Headscale's port requirements](https://headscale.net/stable/setup/requirements/).
4. The official Tailscale client on each Windows and Linux machine, plus a Headscale user and a registration method. Current [Windows client requirements](https://tailscale.com/docs/reference/troubleshooting/windows/supported-windows-versions) are Windows 10+ or Windows Server 2016+.
5. A policy specifying which machines may connect and which services they may use. If using Tailscale SSH, decide whether an `accept` rule is sufficient or a `check` rule with periodic approval is needed.
6. Backups for the Headscale SQLite database, configuration, and private keys, plus an alternate access path for any remotely managed machine during migration.

## Client setup and rollout

1. Provision the VM, DNS, HTTPS, and Headscale. Choose whether to enable embedded DERP and whether to retain Tailscale's public DERP map. Verify the public `https://headscale.example.com/health` endpoint.
2. Create a Headscale user and a policy for the intended clients and services. Validate the policy before applying it.
3. Install the [Windows Tailscale app](https://tailscale.com/docs/install/windows) on each Windows machine. In PowerShell, run `tailscale login --login-server https://headscale.example.com`. For a Windows machine that must stay connected while nobody is signed in, enable **Run unattended** in the app preferences. Follow the registration instructions shown by Headscale.
4. Install the [Linux Tailscale client](https://tailscale.com/docs/install/linux) on each Linux machine. Run `sudo tailscale up --login-server https://headscale.example.com` and complete Headscale registration.
5. Add one test machine first, then add the others one at a time. A client switched to Headscale leaves its previous Tailscale tailnet, so verify an alternate access path before changing a remote machine that depends on that tailnet.
6. Test name resolution, permitted services, `tailscale status`, `tailscale ping <machine>`, direct connectivity, and DERP fallback from another network. If using SSH, test its policy and login behavior. Back up the server data and document how to restore it.

## Drafted configuration

The runnable draft (compose file, minimal Headscale config, starter ACL, backup/restore scripts, cron) is in this directory; deploy steps, operations and known limits are in [README.md](README.md). It has not been run or validated.

Design choices in the draft:
- Docker Compose with a single `headscale` container instead of the [official packages](https://headscale.net/stable/setup/install/official/). Either works; the VM table above still applies.
- Headscale terminates TLS itself (built-in Let's Encrypt, HTTP-01 on TCP 80), so there is no reverse proxy. DERP shares the HTTPS port. Upstream documents reverse proxies as the usual setup, so verify this on the VM.
- The config file lists only keys that differ from Headscale's defaults.
- Embedded DERP on, Tailscale's public DERP map kept as fallback.
- ACL is allow-all between enrolled machines (simple start; tighten with groups or tags later).
- Monitoring is two cron lines (alert on backup failure, alert if no backup in 26 h). An external uptime monitor on `https://<domain>/health` is still needed: a dead VM cannot alert on itself.

## Decisions

Settled:
- Run on a new VM the user creates.
- Enable the embedded DERP and keep the public DERP map as a fallback.
- No OIDC for now: machines join with preauth keys. The ACL is a file, allow-all.

Still open:
- VM provider/location and the DNS name.
- Number of clients and expected traffic, especially large transfers between networks that might require relaying.
- Whether to drop the public DERP map (makes the VM the single relay).
- Whether Tailscale SSH and periodic approval are needed.
- Backup destination and recovery procedure.

## Sources

- [Headscale requirements](https://headscale.net/stable/setup/requirements/)
- [Headscale client support](https://headscale.net/stable/about/clients/)
- [Headscale getting started](https://headscale.net/stable/usage/getting-started/)
- [Headscale Windows setup](https://headscale.net/stable/usage/connect/windows/)
- [Headscale DERP](https://headscale.net/stable/ref/derp/)
- [Headscale scaling FAQ](https://headscale.net/stable/about/faq/)
- [Tailscale connection types](https://tailscale.com/docs/reference/connection-types)

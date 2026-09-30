# Headscale stack

Self-hosted Tailscale control server: Headscale with built-in Let's Encrypt HTTPS, embedded DERP relay, preauth-key enrolment, file-based ACL, backups with offsite upload and alerting.

**Status: config and ACL validated offline against headscale v0.29.4; not yet deployed. TLS, client enrolment, embedded DERP and the scripts have not run on a real VM.** Background, decisions and open questions are in [`tailscale_replacement_system.md`](tailscale_replacement_system.md).

## Files

`docker-compose.yml`, `config/` (`config.yaml.example`, `acl.hujson`; the real `config.yaml` is git-ignored: it is per-deployment), `data/` (created at runtime: DB and private keys), `backup.sh`, `restore.sh`, `headscale-backup.cron`, `test.sh` (runs backup and restore against stub `docker`/`rclone`, ~10 s, no containers needed). Design rationale is in the design doc above.

## Deploy

Needs a Linux VM with a public IP, Docker with the compose plugin, and a DNS name. No identity provider is needed: machines join with preauth keys.

1. **DNS and firewall.** Point an A record for your domain (e.g. `hs.example.com`) at the VM. Open inbound TCP 80, TCP 443, UDP 3478.

2. **Copy the project** to `/opt/headscale` on the VM (the cron file assumes this path).

3. **Create and fill in the config.** `cp config/config.yaml.example config/config.yaml`, then replace every placeholder (`grep -n 'CHANGEME\|example.com' config/config.yaml`):
   - `server_url` and `tls_letsencrypt_hostname`: your domain (same in both)
   - optional: uncomment `derp.server.ipv4` / `ipv6` with the VM's public addresses

   `config/acl.hujson` starts as allow-all between your own machines; tighten it later if needed.

4. 5. **Start and check.**
   ```
   docker compose up -d
   docker compose logs headscale        # look for policy or TLS errors
   curl https://<domain>/health         # first request may take a few seconds while headscale gets a certificate
   docker compose exec headscale headscale policy check -f /etc/headscale/acl.hujson
   ```
   `policy check` talks to the running server, so run it after `up`. If headscale rejects `acl.hujson`, the logs name the line.

6. **Join clients.** Create a user and a preauth key on the server, then run the join command on each machine (Tailscale client installed):
   ```
   docker compose exec headscale headscale users create me
   docker compose exec headscale headscale users list                  # note the ID
   docker compose exec headscale headscale preauthkeys create -u <id> --reusable --expiration 24h
   sudo tailscale up --login-server https://<domain> --authkey <key>   # Linux
   tailscale up --login-server https://<domain> --authkey <key>        # Windows, PowerShell
   ```
   A client moved to Headscale leaves its old tailnet. Keep another way into any remote machine until it is confirmed working.

7. **Verify networking.** `tailscale status`, `tailscale ping <peer>` (`direct` vs `relay`), and `tailscale netcheck` (region `headscale` should show a latency). Then test from a different network.

8. **Set up backups and monitoring.**
   - Install and configure `rclone` (use an encrypted remote: archives contain the server's private keys).
   - Edit `headscale-backup.cron`: set `OFFSITE=<remote:path>` and `ALERT_URL=<ntfy topic or webhook>`.
   - `sudo cp headscale-backup.cron /etc/cron.d/headscale-backup`
   - Run `./backup.sh` once by hand and confirm the archive and the offsite copy exist. Confirm alerts arrive: `curl -fsS -d test "$ALERT_URL"`.
   - Add an external uptime monitor. If the VM dies, its own cron cannot alert. Use a hosted service (e.g. UptimeRobot, Better Stack) with:
     - Type: keyword HTTP(s); URL `https://<domain>/health`; keyword `pass` (alert when it does not exist). `/health` returns `{"status":"pass"}`.
     - Interval 5 min, timeout 30 s, alert after 2 consecutive failures.
     - Alert contacts: email or app push; a webhook can post plain text to the same ntfy topic as `ALERT_URL` if the plan allows it.
     - Turn on certificate-expiry alerts if offered: this catches a failed automatic renewal.
     - To test, stop the container or host briefly at a quiet time: existing peers keep working, but new logins fail while control is down.
     - It checks reachability only, not enrolment or DERP relaying. Check those from a client with `tailscale status` and `tailscale netcheck`.

9. **Try a restore** before you need one (ideally on a scratch VM): `./restore.sh backups/headscale-<timestamp>.tar.gz`.

## Running in a Proxmox LXC

Untested; the steps below are the usual setup for Docker in an LXC.

1. Create a Debian 12 (or Ubuntu 22.04+) LXC: **unprivileged**, 1 vCPU, 1 GB RAM, 10-20 GB disk, bridged network with its own IP (static, or a DHCP reservation).
2. In the container's Options -> Features enable **nesting** and **keyctl** (or `features: nesting=1,keyctl=1` in `/etc/pve/lxc/<id>.conf`), then restart it. Docker will not start without nesting.
3. Inside the LXC install Docker and the compose plugin, then continue with the deploy steps above. `docker compose`, cron and `rclone` all run inside the LXC.
4. Make it reachable: forward TCP 80, TCP 443 and UDP 3478 from your router (or the Proxmox host's firewall) to the LXC's IP. Port 80 must really reach it for the Let's Encrypt HTTP-01 challenge.
5. If `docker run` fails on overlay or storage errors (seen with LXC root disks on ZFS), set Docker's storage driver to `fuse-overlayfs` or use a VM instead.

The LXC does not need `/dev/net/tun`: the headscale server does not create a VPN interface. Only Tailscale **clients** running in containers do (pass through `/dev/net/tun` or use userspace mode).

Proxmox backups (`vzdump`) of the LXC also capture `data/` and `config/`, but they are not application-consistent for SQLite: keep `backup.sh` as the primary backup.

## Managing users and devices

Headscale has no web UI (`/` is a blank page on purpose; `/health`, `/windows` and `/apple` exist). Everything is done with the `headscale` CLI inside the container, from a shell on the host, in the project directory:

```
cd /opt/headscale
hs="docker compose exec -T headscale headscale"      # shorthand for the examples below
```

A "user" is an owner of devices (there are no passwords or web accounts). A "node" is a device.

| Task | Command |
|---|---|
| List devices | `$hs nodes list` |
| Rename a device | `$hs nodes rename -i <id> <new-name>` |
| Force re-authentication | `$hs nodes expire -i <id>` |
| Never expire a device's key (servers) | `$hs nodes expire -i <id> --disable` |
| Remove a device | `$hs nodes delete -i <id>` |
| Approve subnet routes / exit node | `$hs nodes approve-routes -i <id> -r 10.0.0.0/24` (empty `-r ""` removes all) |
| Show advertised routes | `$hs nodes list-routes` |
| Tag a device (ACL use) | `$hs nodes tag -i <id> -t tag:server` (tags must start with `tag:`; a tagged device is owned by its tags, not by a user) |
| List / create / rename users | `$hs users list`, `$hs users create <name>`, `$hs users rename -i <id> --new-name <name>` |
| Delete a user (remove their devices first) | `$hs users destroy -i <id>` |
| Create a preauth key | `$hs preauthkeys create -u <user-id> --expiration 1h` (one machine; add `--reusable` for several) |
| List / expire / delete keys | `$hs preauthkeys list`, `$hs preauthkeys expire --id <n>`, `$hs preauthkeys delete --id <n>` |
| Approve a device that ran `tailscale up` without a key | `$hs auth register --auth-id <id-from-the-url> --user <name>` |

Add `-o json` to most commands for scripting. `$hs <command> --help` shows the flags for this version.

On any machine: `tailscale status` (peers), `tailscale ping <name>` (direct vs relay), `tailscale netcheck` (DERP), `tailscale down` (disconnect), `tailscale logout` (leave the network).

Remote CLI (running `headscale` from another PC with an API key) needs the gRPC port exposed, which this stack does not do. Add it only if needed.

## Operations

- **Add a machine:** create a preauth key and run `tailscale up` with it (step 6).
- **Change the ACL:** edit `config/acl.hujson`, run `policy check`, then `docker compose restart headscale`.
- **Upgrade:** bump the image tag in `docker-compose.yml`, run `./backup.sh`, then `docker compose pull && docker compose up -d`. Read the Headscale release notes first; config keys change between versions.
- **Restore:** `./restore.sh <archive>` moves the current state aside as `*.pre-restore.<timestamp>` (nothing is deleted). Offsite archive: `rclone copy "$OFFSITE/<file>" backups/` first.
- **Logs:** `docker compose logs -f headscale`; backup log at `/var/log/headscale-backup.log`.

## Known limits

- No SSH policy or metrics protection yet. The ACL is allow-all. OIDC login can be added later (`oidc:` block, see the Headscale docs).
- Tailscale's public DERP map is kept as a fallback. Set `derp.urls: []` to make your VM the only relay (single point of failure).
- Backups briefly stop headscale (a few seconds). Offsite copies are not pruned; use a bucket lifecycle rule.
- The offsite copy itself is not verified, only that the upload did not fail.

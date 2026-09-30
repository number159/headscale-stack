# Headscale stack

Self-hosted Tailscale control server: Headscale with built-in Let's Encrypt HTTPS, embedded DERP relay, OIDC login, file-based ACL, backups with offsite upload and alerting.

**Status: config and ACL validated offline against headscale v0.29.4; not yet deployed. TLS, OIDC login, embedded DERP and the scripts have not run on a real VM.** Background, decisions and open questions are in [`tailscale_replacement_system.md`](tailscale_replacement_system.md).

## Files

`docker-compose.yml`, `config/` (`config.yaml.example`, `acl.hujson`; the real `config.yaml` is git-ignored because it holds the OIDC secret), `data/` (created at runtime: DB and private keys), `backup.sh`, `restore.sh`, `headscale-backup.cron`, `test.sh` (runs backup and restore against stub `docker`/`rclone`, ~10 s, no containers needed). Design rationale is in the design doc above.

## Deploy

Needs a Linux VM with a public IP, Docker with the compose plugin, a DNS name, and an OIDC identity provider.

1. **DNS and firewall.** Point an A record for your domain (e.g. `hs.example.com`) at the VM. Open inbound TCP 80, TCP 443, UDP 3478.

2. **Copy the project** to `/opt/headscale` on the VM (the cron file assumes this path).

3. **Register an OIDC client** at your identity provider with redirect URI `https://<domain>/oidc/callback`. Note the issuer URL, client ID and secret.

4. **Create and fill in the config.** `cp config/config.yaml.example config/config.yaml` (git-ignored: it holds the OIDC secret), then replace every placeholder (`grep -rn 'CHANGEME\|example.com' config/config.yaml config/acl.hujson`):
   - `config/config.yaml`: `server_url` and `tls_letsencrypt_hostname` (same domain), `oidc.issuer`, `oidc.client_id`, `oidc.client_secret`, `oidc.allowed_domains` (or `allowed_users` / `allowed_groups`)
   - `config/config.yaml`, optional: uncomment `derp.server.ipv4` / `ipv6` with the VM's public addresses
   - `config/acl.hujson`: your admin email(s) in `group:admin`, exactly as the IdP returns them

5. **Start and check.**
   ```
   docker compose up -d
   docker compose logs headscale        # look for policy or OIDC errors
   curl https://<domain>/health         # first request may take a few seconds while headscale gets a certificate
   docker compose exec headscale headscale policy check -f /etc/headscale/acl.hujson
   ```
   `policy check` talks to the running server, so run it after `up`. If headscale rejects `acl.hujson`, the logs name the line.

6. **Join a first client** (Tailscale client installed):
   ```
   sudo tailscale up --login-server https://<domain>      # Linux; open the printed URL, sign in via OIDC
   tailscale login --login-server https://<domain>       # Windows, PowerShell
   ```
   Headless machine: create a preauth key and pass it with `--authkey`.
   ```
   docker compose exec headscale headscale users list
   docker compose exec headscale headscale preauthkeys create -u <user-id> --reusable --expiration 24h
   ```
   A client moved to Headscale leaves its old tailnet. Keep another way into any remote machine until it is confirmed working.

7. **Verify networking.** `tailscale status`, `tailscale ping <peer>` (`direct` vs `relay`), and `tailscale netcheck` (region `headscale` should show a latency). Then test from a different network.

8. **Set up backups and monitoring.**
   - Install and configure `rclone` (use an encrypted remote: archives contain private keys and the OIDC secret).
   - Edit `headscale-backup.cron`: set `OFFSITE=<remote:path>` and `ALERT_URL=<ntfy topic or webhook>`.
   - `sudo cp headscale-backup.cron /etc/cron.d/headscale-backup`
   - Run `./backup.sh` once by hand and confirm the archive and the offsite copy exist. Confirm alerts arrive: `curl -fsS -d test "$ALERT_URL"`.
   - Add an external uptime monitor on `https://<domain>/health`. If the VM dies, its own cron cannot alert.

9. **Try a restore** before you need one (ideally on a scratch VM): `./restore.sh backups/headscale-<timestamp>.tar.gz`.

## Operations

- **Add a user or machine:** log in through OIDC, or use a preauth key (step 6).
- **Change the ACL:** edit `config/acl.hujson`, run `policy check`, then `docker compose restart headscale`.
- **Upgrade:** bump the image tag in `docker-compose.yml`, run `./backup.sh`, then `docker compose pull && docker compose up -d`. Read the Headscale release notes first; config keys change between versions.
- **Restore:** `./restore.sh <archive>` moves the current state aside as `*.pre-restore.<timestamp>` (nothing is deleted). Offsite archive: `rclone copy "$OFFSITE/<file>" backups/` first.
- **Logs:** `docker compose logs -f headscale`; backup log at `/var/log/headscale-backup.log`.

## Known limits

- No SSH policy, metrics protection or OIDC group-based ACLs yet.
- Tailscale's public DERP map is kept as a fallback. Set `derp.urls: []` to make your VM the only relay (single point of failure).
- Backups briefly stop headscale (a few seconds). Offsite copies are not pruned; use a bucket lifecycle rule.
- The offsite copy itself is not verified, only that the upload did not fail.

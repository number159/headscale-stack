#!/usr/bin/env bash
# Backs up data/ (SQLite + private keys) and config/ (incl. OIDC secret) to ./backups (keeps 14),
# then copies the archive offsite with rclone if OFFSITE is set.
# Stops headscale for a second or two so the SQLite file is consistent.
# ponytail: brief stop instead of sqlite online backup; clients reconnect on their own.
#
# OFFSITE=<rclone remote:path>  e.g. b2:my-bucket/headscale  (set here or in the cron env)
# The archive holds private keys and the OIDC secret: use an encrypted remote (rclone crypt).
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p backups
out="backups/headscale-$(date +%Y%m%d-%H%M%S).tar.gz"
[ ! -e "$out" ] || { echo "$out already exists" >&2; exit 1; }   # one backup per second; never clobber

docker compose stop headscale
trap 'rm -f "$out"; docker compose start headscale' EXIT   # no partial archive on failure

umask 077
tar czf "$out" data config
tar tzf "$out" >/dev/null   # fail loudly if the archive is unreadable

docker compose start headscale   # back up before uploading; upload can be slow
trap - EXIT

ls -1t backups/headscale-*.tar.gz | tail -n +15 | xargs -r rm --
echo "wrote $out"

if [ -n "${OFFSITE:-}" ]; then
  rclone copy "$out" "$OFFSITE"
  echo "uploaded to $OFFSITE"
else
  echo "OFFSITE not set: no offsite copy" >&2
fi

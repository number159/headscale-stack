#!/usr/bin/env bash
# Usage: ./restore.sh backups/headscale-<timestamp>.tar.gz
# Replaces data/ and config/ with the archive's contents and restarts the stack.
# Current copies are moved aside as *.pre-restore.<timestamp>, not deleted.
# Offsite archive: fetch it first, e.g. rclone copy "$OFFSITE/<file>" backups/
set -euo pipefail
cd "$(dirname "$0")"

archive=${1:?usage: $0 <archive.tar.gz>}
[ -f "$archive" ] || { echo "no such file: $archive" >&2; exit 1; }
archive=$(realpath "$archive")

# must contain what backup.sh writes (list once: grep -q under pipefail trips on SIGPIPE)
files=$(tar tzf "$archive") || { echo "unreadable archive: $archive" >&2; exit 1; }
grep -q '^data/' <<<"$files" && grep -q '^config/' <<<"$files" \
  || { echo "not a headscale backup: $archive" >&2; exit 1; }

ts=$(date +%Y%m%d-%H%M%S)
docker compose down
for p in data config; do
  [ -e "$p" ] && mv "$p" "$p.pre-restore.$ts"
done

umask 077
tar xzf "$archive"
docker compose up -d
echo "restored $archive; previous state kept as *.pre-restore.$ts"

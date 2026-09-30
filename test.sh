#!/usr/bin/env bash
# Runs backup.sh and restore.sh in a temp dir with stub `docker` and `rclone`. No containers needed.
# Usage: ./test.sh   (exit 0 = all pass)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir "$t/bin" "$t/p"

for c in docker rclone; do   # stubs just record their calls
  printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n' "$c" > "$t/bin/$c"; chmod +x "$t/bin/$c"
done
export PATH="$t/bin:$PATH" CALLS="$t/p/calls"
cp "$here/backup.sh" "$here/restore.sh" "$t/p/"; cd "$t/p"

ok() { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }
check() { local d=$1; shift; "$@" || fail "$d"; ok "$d"; }

mkdir data config; echo db-v1 > data/db.sqlite; echo cfg-v1 > config/config.yaml

# --- backup: archive contents, docker order, no offsite when OFFSITE unset
./backup.sh >/dev/null 2>&1
arc=$(ls backups/headscale-*.tar.gz)
check "archive has data and config" bash -c "tar tzf $arc | grep -q '^data/db.sqlite' && tar tzf $arc | grep -q '^config/config.yaml'"
check "archive is mode 600" test "$(stat -c %a "$arc")" = 600
check "headscale stopped then started" bash -c "[ \"\$(grep -o 'stop\|start' calls | tr '\n' ' ')\" = 'stop start ' ]"
check "no rclone call without OFFSITE" bash -c "! grep -q rclone calls"

# --- offsite upload
: > calls
sleep 1   # archive names are per-second
OFFSITE=remote:bucket ./backup.sh >/dev/null 2>&1
check "rclone copies newest archive to OFFSITE" bash -c "grep -q '^rclone copy backups/headscale-.*tar.gz remote:bucket\$' calls"

# --- retention: keep newest 14
rm backups/*
for i in $(seq 1 16); do touch -d "$i days ago" "backups/headscale-old$i.tar.gz"; done
./backup.sh >/dev/null 2>&1
check "keeps 14 archives" test "$(ls backups | wc -l)" = 14
check "newest archive survives pruning" bash -c "ls backups | grep -qv old"
check "oldest archives pruned" test ! -e backups/headscale-old16.tar.gz

# --- backup failure still restarts headscale
sleep 1; mv data data.away; : > calls
./backup.sh >/dev/null 2>&1 && fail "backup should fail without data/"
mv data.away data
check "headscale restarted after failed backup" grep -q 'docker compose start headscale' calls
check "no partial archive left behind" test "$(ls backups | wc -l)" = 14

# --- restore
arc=$(ls -t backups/headscale-*.tar.gz | head -1)
echo db-v2 > data/db.sqlite; echo cfg-v2 > config/config.yaml
# the newest archive holds v1 (taken before the edit above), so restore must bring v1 back
: > calls
./restore.sh "$arc" >/dev/null 2>&1
check "restore brings back data" test "$(cat data/db.sqlite)" = db-v1
check "restore brings back config" test "$(cat config/config.yaml)" = cfg-v1
check "previous data kept aside" bash -c "cat data.pre-restore.*/db.sqlite | grep -q db-v2"
check "previous config kept aside" bash -c "cat config.pre-restore.*/config.yaml | grep -q cfg-v2"
check "restore does down then up" bash -c "[ \"\$(grep -o 'down\|up' calls | tr '\n' ' ')\" = 'down up ' ]"

# --- restore rejects bad input and changes nothing
: > calls
echo not-a-tar > bad.tar.gz
./restore.sh bad.tar.gz >/dev/null 2>&1 && fail "restore accepted a non-archive"
./restore.sh missing.tar.gz >/dev/null 2>&1 && fail "restore accepted a missing file"
tar czf other.tar.gz bad.tar.gz
./restore.sh other.tar.gz >/dev/null 2>&1 && fail "restore accepted a non-headscale archive"
check "bad archives touch neither docker nor data" bash -c "[ ! -s calls ] && [ \"\$(cat data/db.sqlite)\" = db-v1 ]"

echo "all passed"

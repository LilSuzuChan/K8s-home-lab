#!/bin/sh
set -eu

base="seaweedfs:kfp-db-backup/mysql"
if [ -n "${BACKUP_RUN_ID:-}" ]; then
  path=$(rclone lsf -R --dirs-only "$base" | grep "/${BACKUP_RUN_ID}/\$" | head -n 1)
else
  path=$(rclone lsf -R --files-only --include "*/dump.sql.gz" "$base" | sort | tail -n 1 | sed 's#/dump.sql.gz$#/#')
fi
[ -n "$path" ] || { echo "[fetch] FAIL: no backup found"; exit 1; }
rclone copy "$base/$path" /work --include "dump.sql.gz" --include "dump.sql.gz.sha256" --include "meta.json"
[ "$(sha256sum /work/dump.sql.gz | cut -d' ' -f1)" = "$(cat /work/dump.sql.gz.sha256)" ] || { echo "[fetch] FAIL: sha256 mismatch"; exit 1; }
echo "[fetch] mysql/$path sha256 verified: $(cat /work/meta.json)"

#!/bin/sh
set -eu

log() {
  echo "[upload] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
}

fail() {
  log "FAIL: $*" >&2
  exit 1
}

[ "$BACKUP_BUCKET" = "kfp-db-backup" ] || fail "unexpected bucket $BACKUP_BUCKET"
[ -s /work/dump.sql.gz ] && [ -s /work/meta.json ] || fail "dump files are missing"
[ "$(sha256sum /work/dump.sql.gz | cut -d' ' -f1)" = "$(cat /work/dump.sql.gz.sha256)" ] || fail "local sha256 mismatch"

run_id=$(sed -n 's/.*"runId":"\([^"]*\)".*/\1/p' /work/meta.json)
day=$(echo "$run_id" | sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2}).*/\1\/\2\/\3/')
dest="seaweedfs:$BACKUP_BUCKET/mysql/$day/$run_id"

rclone copy /work "$dest" --include "dump.sql.gz" --include "dump.sql.gz.sha256" --include "meta.json"
remote=$(rclone cat "$dest/dump.sql.gz" | sha256sum | cut -d' ' -f1)
[ "$remote" = "$(cat /work/dump.sql.gz.sha256)" ] || fail "uploaded dump sha256 mismatch"
log "uploaded mysql/$day/$run_id (sha256 verified)"

count=$(rclone lsf -R --files-only --include "*/dump.sql.gz" "seaweedfs:$BACKUP_BUCKET/mysql" | wc -l)
if [ "$count" -gt "$KEEP_MIN" ]; then
  rclone delete --min-age "${RETENTION_DAYS}d" "seaweedfs:$BACKUP_BUCKET/mysql"
  rclone rmdirs --leave-root "seaweedfs:$BACKUP_BUCKET/mysql" 2>/dev/null || true
  log "removed backups older than ${RETENTION_DAYS} days (had $count backups)"
else
  log "kept all $count backups (minimum $KEEP_MIN)"
fi

cp /work/meta.json /tmp/last-success.json
rclone copyto /tmp/last-success.json "seaweedfs:$BACKUP_BUCKET/status/last-success.json"
log "PASS"

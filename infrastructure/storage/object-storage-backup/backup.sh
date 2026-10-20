#!/bin/sh
set -eu

log() {
  echo "[backup] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
}

fail() {
  log "FAIL: $*" >&2
  exit 1
}

case "${BACKUP_BUCKET:-}" in
  homelab-seaweedfs-backup-*) ;;
  *) fail "BACKUP_BUCKET is not a homelab backup bucket" ;;
esac

src="seaweedfs:"
dest="aws:$BACKUP_BUCKET"
run_id=$(date -u +%Y%m%dT%H%M%SZ)
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
work=$(mktemp -d)
exclude="/restore-*/**"

buckets=$(rclone lsf --dirs-only --exclude "$exclude" "$src" | tr -d '/' | paste -sd' ' -)
log "source buckets: ${buckets:-<none>}"

rclone copy "$src" "$dest/seaweedfs" --exclude "$exclude" \
  --fast-list --transfers 4 --checkers 8 \
  --stats 60s --stats-one-line --stats-log-level NOTICE
log "copy finished"

rclone check "$src" "$dest/seaweedfs" --exclude "$exclude" --one-way --fast-list
log "check passed"

rclone lsjson -R --files-only --hash --exclude "$exclude" "$src" > "$work/manifest.json"
rclone copyto "$work/manifest.json" "$dest/manifests/$run_id.json"
log "manifest written: manifests/$run_id.json"

size=$(rclone size --json --exclude "$exclude" "$src")
printf '{"runId":"%s","startedAt":"%s","finishedAt":"%s","manifest":"manifests/%s.json","source":%s}\n' \
  "$run_id" "$started" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$run_id" "$size" > "$work/last-success.json"
rclone copyto "$work/last-success.json" "$dest/status/last-success.json"
log "status: $(cat "$work/last-success.json")"
log "PASS"

#!/bin/sh
set -eu

mode="${1:?usage: restore-drill.sh restore|retained|versions|cleanup}"
source_bucket="${DRILL_SOURCE_BUCKET:-s3-smoke-test}"
restore_bucket="${DRILL_RESTORE_BUCKET:-restore-drill}"
backup="aws:$BACKUP_BUCKET/seaweedfs/$source_bucket"
work=$(mktemp -d)

log() {
  echo "[$mode] $*"
}

fail() {
  echo "[$mode] FAIL: $*" >&2
  exit 1
}

hashes() {
  rclone hashsum sha256 --download "$@" | sort -k2
}

same() {
  if ! diff "$1" "$2" >/dev/null; then
    diff "$1" "$2" >&2 || true
    fail "$3"
  fi
  log "$3: OK"
}

must_fail() {
  description=$1
  shift
  if "$@" >"$work/denied.log" 2>&1; then
    fail "$description succeeded"
  fi
  grep -qi 'AccessDenied\|403\|Forbidden' "$work/denied.log" || {
    cat "$work/denied.log" >&2
    fail "$description failed with an unexpected error"
  }
  log "$description denied: OK"
}

case "$restore_bucket" in
  restore-*) ;;
  *) fail "restore bucket must start with restore-" ;;
esac

case "$mode" in
  restore)
    rclone lsl "$backup"
    hashes "$backup" > "$work/backup.sha256"
    [ -s "$work/backup.sha256" ] || fail "no objects under seaweedfs/$source_bucket in the backup bucket"
    hashes "seaweedfs:$source_bucket" > "$work/source.sha256"
    same "$work/source.sha256" "$work/backup.sha256" "source and backup sha256 match"
    expected=$(rclone cat "$backup/smoke/random.bin.sha256")
    grep -q "^$expected  smoke/random.bin\$" "$work/backup.sha256" || fail "backup sha256 differs from the hash recorded at write time"
    log "backup sha256 matches the hash recorded at write time: OK"
    if rclone lsf "restore:$restore_bucket" >/dev/null 2>&1; then
      fail "restore bucket $restore_bucket already exists; run cleanup first"
    fi
    rclone copy "$backup" "restore:$restore_bucket"
    hashes "restore:$restore_bucket" > "$work/restored.sha256"
    same "$work/source.sha256" "$work/restored.sha256" "source and restored sha256 match"
    printf 'drill\n' > "$work/probe.txt"
    must_fail "writer delete in AWS" rclone deletefile "awswriter:$BACKUP_BUCKET/seaweedfs/$source_bucket/smoke/random.bin.sha256"
    must_fail "writer write outside backup prefixes" rclone copyto "$work/probe.txt" "awswriter:$BACKUP_BUCKET/drill/probe.txt"
    must_fail "reader write in AWS" rclone copyto "$work/probe.txt" "aws:$BACKUP_BUCKET/seaweedfs/drill-probe.txt"
    must_fail "backup identity write in SeaweedFS" rclone copyto "$work/probe.txt" "seaweedfs:$source_bucket/drill-probe.txt"
    must_fail "restore identity read of a production bucket" rclone lsf "restore:$source_bucket"
    hashes "$backup" > "$work/after.sha256"
    same "$work/backup.sha256" "$work/after.sha256" "backup unchanged after denied requests"
    ;;
  retained)
    if rclone lsf "seaweedfs:$source_bucket" >/dev/null 2>&1; then
      fail "source bucket $source_bucket still exists; delete it with the s3-smoke cleanup job first"
    fi
    log "source bucket $source_bucket is gone"
    hashes "$backup" > "$work/backup.sha256"
    hashes "restore:$restore_bucket" > "$work/restored.sha256"
    same "$work/restored.sha256" "$work/backup.sha256" "backup still holds the deleted objects"
    ;;
  versions)
    hashes "seaweedfs:$source_bucket" > "$work/source.sha256"
    hashes "$backup" > "$work/backup.sha256"
    same "$work/source.sha256" "$work/backup.sha256" "current backup matches the overwritten source"
    hashes "restore:$restore_bucket" > "$work/restored.sha256"
    if diff "$work/restored.sha256" "$work/backup.sha256" >/dev/null; then
      fail "overwritten objects have the same sha256 as before; the overwrite was not backed up"
    fi
    count=$(rclone lsf --s3-versions "$backup/smoke/" | grep -cE '^random(-v[0-9-]+)?\.bin$')
    [ "$count" -ge 2 ] || fail "expected at least 2 versions of smoke/random.bin, found $count"
    log "smoke/random.bin has $count versions: OK"
    at=$(rclone lsf "aws:$BACKUP_BUCKET/manifests/" | sort | tail -n 2 | head -n 1 \
      | sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z\.json$/\1-\2-\3T\4:\5:\6Z/')
    log "point in time: $at"
    hashes --s3-version-at "$at" "$backup" > "$work/at.sha256"
    same "$work/restored.sha256" "$work/at.sha256" "point-in-time view matches the first backup"
    ;;
  cleanup)
    rclone purge "restore:$restore_bucket"
    if rclone lsf "restore:$restore_bucket" >/dev/null 2>&1; then
      fail "restore bucket $restore_bucket still exists"
    fi
    log "deleted restore bucket $restore_bucket"
    ;;
  *)
    fail "unknown mode"
    ;;
esac

log "PASS"

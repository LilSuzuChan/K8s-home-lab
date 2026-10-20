#!/bin/bash
set -euo pipefail
umask 077

log() {
  echo "[dump] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
}

[[ "$MYSQL_BACKUP_PASSWORD" =~ ^[A-Za-z0-9+/=]{16,}$ ]] || { log "FAIL: unexpected password format"; exit 1; }
printf '[client]\nuser=%s\npassword=%s\nhost=%s\nport=%s\n' "$MYSQL_BACKUP_USER" "$MYSQL_BACKUP_PASSWORD" "$MYSQL_HOST" "$MYSQL_PORT" > /tmp/my.cnf

umask 027
started_epoch=$(date -u +%s)
run_id=$(date -u -d "@$started_epoch" +%Y%m%dT%H%M%SZ)
log "dumping databases: $DATABASES"
mysqldump --defaults-extra-file=/tmp/my.cnf \
  --single-transaction --quick --no-tablespaces --hex-blob \
  --skip-triggers --set-gtid-purged=OFF \
  --databases $DATABASES | gzip -9 > /work/dump.sql.gz
gzip -t /work/dump.sql.gz
gzip -dc /work/dump.sql.gz | tail -n 1 | grep -q '^-- Dump completed' || { log "FAIL: dump is incomplete"; exit 1; }
sha256sum /work/dump.sql.gz | cut -d' ' -f1 > /work/dump.sql.gz.sha256
size=$(stat -c %s /work/dump.sql.gz)
version=$(mysqldump --version | head -n 1)
printf '{"runId":"%s","startedEpoch":%s,"databases":"%s","bytes":%s,"sha256":"%s","mysqldump":"%s"}\n' \
  "$run_id" "$started_epoch" "$DATABASES" "$size" "$(cat /work/dump.sql.gz.sha256)" "$version" > /work/meta.json
rm -f /tmp/my.cnf
log "dump ok: $(cat /work/meta.json)"

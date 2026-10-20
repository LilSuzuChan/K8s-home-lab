#!/bin/bash
set -euo pipefail
umask 077

log() {
  echo "[verify] $*"
}

fail() {
  log "FAIL: $*" >&2
  exit 1
}

restored() {
  mysql --socket=/var/run/mysqld/mysqld.sock -uroot -N -B -e "$1"
}

production() {
  mysql --defaults-extra-file=/tmp/prod.cnf -N -B -e "$1"
}

printf '[client]\nuser=%s\npassword=%s\nhost=mysql.kubeflow.svc.cluster.local\n' "$MYSQL_BACKUP_USER" "$MYSQL_BACKUP_PASSWORD" > /tmp/prod.cnf

for i in $(seq 1 60); do
  mysqladmin --socket=/var/run/mysqld/mysqld.sock -uroot ping >/dev/null 2>&1 && break
  sleep 2
done
mysqladmin --socket=/var/run/mysqld/mysqld.sock -uroot ping >/dev/null || fail "temporary mysqld is not ready"

started=$(sed -n 's/.*"startedEpoch":\([0-9]*\).*/\1/p' /work/meta.json)
[ -n "$started" ] || fail "meta.json has no startedEpoch"
log "restoring dump taken at epoch $started into the temporary server"
gzip -dc /work/dump.sql.gz | mysql --socket=/var/run/mysqld/mysqld.sock -uroot
log "restore finished"

for db in mlpipeline metadb; do
  q="SELECT table_name FROM information_schema.tables WHERE table_schema='$db' ORDER BY table_name"
  diff <(production "$q") <(restored "$q") >/dev/null || fail "table list of $db differs"
  log "$db tables match production: $(restored "$q" | wc -l)"
done

compare() {
  local name=$1 query=$2 missing
  missing=$(comm -23 <(production "$query" | sort) <(restored "$query" | sort) | wc -l)
  [ "$missing" -eq 0 ] || fail "$missing $name created before the backup are missing"
  log "$name created before the backup: $(production "$query" | wc -l) in production, all present in the restore"
}

compare "runs" "SELECT UUID FROM mlpipeline.run_details WHERE CreatedAtInSec <= $started"
compare "pipelines" "SELECT UUID FROM mlpipeline.pipelines WHERE CreatedAtInSec <= $started"
compare "MLMD executions" "SELECT id FROM metadb.Execution WHERE create_time_since_epoch <= $started * 1000"
compare "MLMD artifacts" "SELECT id, uri FROM metadb.Artifact WHERE create_time_since_epoch <= $started * 1000"

log "row counts in the restore: runs=$(restored 'SELECT COUNT(*) FROM mlpipeline.run_details') tasks=$(restored 'SELECT COUNT(*) FROM mlpipeline.tasks') executions=$(restored 'SELECT COUNT(*) FROM metadb.Execution') artifacts=$(restored 'SELECT COUNT(*) FROM metadb.Artifact')"
rm -f /tmp/prod.cnf
log "PASS"

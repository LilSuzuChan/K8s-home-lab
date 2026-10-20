#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

NAMESPACE="object-storage"
SECRET="seaweedfs-s3-credentials"
STATEFULSET="seaweedfs"
BACKUP_NAMESPACE="object-storage-backup"
BACKUP_SECRET="seaweedfs-backup-source"
RESTORE_SECRET="seaweedfs-restore"
ADMIN_ACTIONS='"Admin","Read","List","Tagging","Write"'
BACKUP_ACTIONS='"Read","List"'
RESTORE_ACTIONS='"Admin:restore-*"'

usage() {
  cat <<'USAGE'
Usage: s3-credentials.sh <command>

Commands:
  create                Generate new S3 credentials and create the Secret (fails if it already exists)
  rotate --yes          Replace every credential and restart SeaweedFS (old keys stop working)
  backup-identities --yes
                        Generate the read-only "backup" and the "restore" (restore-* buckets only)
                        identities, keep the admin keys, restart SeaweedFS and sync the backup Secrets
  sync-backup           Copy the backup and restore keys into the object-storage-backup namespace
  status                Show Secret metadata and key fingerprints without revealing any value
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

kube() {
  kubectl -n "$NAMESPACE" "$@"
}

b64() {
  printf '%s' "$1" | openssl base64 -A
}

preflight() {
  command -v kubectl >/dev/null || die "kubectl not found"
  command -v openssl >/dev/null || die "openssl not found"
  echo "context: $(kubectl config current-context)"
  echo "server:  $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  kubectl get namespace "$NAMESPACE" >/dev/null || die "namespace $NAMESPACE not found (apply data/ first)"
}

secret_exists() {
  kubectl -n "$1" get secret "$2" >/dev/null 2>&1
}

read_key() {
  kube get secret "$SECRET" -o "jsonpath={.data.$1}" | openssl base64 -d -A
}

new_access_key() {
  openssl rand -hex 10 | tr 'a-f' 'A-F'
}

new_secret_key() {
  openssl rand -base64 30
}

identity_json() {
  printf '{"name":"%s","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":[%s]}' "$1" "$2" "$3" "$4"
}

render_secret() {
  local s3_json now
  for value in "$ADMIN_AK" "$BACKUP_AK" "$RESTORE_AK"; do
    [[ ${#value} -eq 20 ]] || die "invalid access key length"
  done
  for value in "$ADMIN_SK" "$BACKUP_SK" "$RESTORE_SK"; do
    [[ ${#value} -eq 40 ]] || die "invalid secret key length"
  done
  s3_json=$(printf '{"identities":[%s,%s,%s]}' \
    "$(identity_json admin "$ADMIN_AK" "$ADMIN_SK" "$ADMIN_ACTIONS")" \
    "$(identity_json backup "$BACKUP_AK" "$BACKUP_SK" "$BACKUP_ACTIONS")" \
    "$(identity_json restore "$RESTORE_AK" "$RESTORE_SK" "$RESTORE_ACTIONS")")
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cat <<YAML
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: ${SECRET}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: seaweedfs
    app.kubernetes.io/part-of: object-storage
  annotations:
    object-storage.homelab/generated-at: "${now}"
    object-storage.homelab/identity: "admin,backup,restore"
data:
  s3.json: $(b64 "$s3_json")
  AWS_ACCESS_KEY_ID: $(b64 "$ADMIN_AK")
  AWS_SECRET_ACCESS_KEY: $(b64 "$ADMIN_SK")
  BACKUP_ACCESS_KEY_ID: $(b64 "$BACKUP_AK")
  BACKUP_SECRET_ACCESS_KEY: $(b64 "$BACKUP_SK")
  RESTORE_ACCESS_KEY_ID: $(b64 "$RESTORE_AK")
  RESTORE_SECRET_ACCESS_KEY: $(b64 "$RESTORE_SK")
YAML
}

render_client_secret() {
  cat <<YAML
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: $1
  namespace: ${BACKUP_NAMESPACE}
  labels:
    app.kubernetes.io/name: seaweedfs-backup
    app.kubernetes.io/part-of: object-storage-backup
  annotations:
    object-storage.homelab/identity: "$2"
    object-storage.homelab/source: "${NAMESPACE}/${SECRET}"
data:
  AWS_ACCESS_KEY_ID: $(b64 "$3")
  AWS_SECRET_ACCESS_KEY: $(b64 "$4")
YAML
}

upsert() {
  if secret_exists "$1" "$2"; then
    kubectl replace -f - >/dev/null
  else
    kubectl create -f - >/dev/null
  fi
}

generate_backup_identities() {
  BACKUP_AK=$(new_access_key)
  BACKUP_SK=$(new_secret_key)
  RESTORE_AK=$(new_access_key)
  RESTORE_SK=$(new_secret_key)
}

generate_admin_identity() {
  ADMIN_AK=$(new_access_key)
  ADMIN_SK=$(new_secret_key)
}

restart_seaweedfs() {
  if kube get statefulset "$STATEFULSET" >/dev/null 2>&1; then
    kube rollout restart "statefulset/$STATEFULSET"
    kube rollout status "statefulset/$STATEFULSET" --timeout=300s
  fi
}

sync_backup_secrets() {
  if ! kubectl get namespace "$BACKUP_NAMESPACE" >/dev/null 2>&1; then
    echo "namespace $BACKUP_NAMESPACE not found; run 'sync-backup' after applying object-storage-backup/"
    return
  fi
  [[ -n "$(read_key BACKUP_ACCESS_KEY_ID)" ]] || die "secret $NAMESPACE/$SECRET has no backup identity; run 'backup-identities --yes'"
  render_client_secret "$BACKUP_SECRET" backup "$(read_key BACKUP_ACCESS_KEY_ID)" "$(read_key BACKUP_SECRET_ACCESS_KEY)" \
    | upsert "$BACKUP_NAMESPACE" "$BACKUP_SECRET"
  render_client_secret "$RESTORE_SECRET" restore "$(read_key RESTORE_ACCESS_KEY_ID)" "$(read_key RESTORE_SECRET_ACCESS_KEY)" \
    | upsert "$BACKUP_NAMESPACE" "$RESTORE_SECRET"
  echo "synced secrets $BACKUP_NAMESPACE/$BACKUP_SECRET and $BACKUP_NAMESPACE/$RESTORE_SECRET (values are not shown)"
}

cmd_create() {
  preflight
  secret_exists "$NAMESPACE" "$SECRET" && die "secret $NAMESPACE/$SECRET already exists; use 'rotate --yes' to replace it"
  generate_admin_identity
  generate_backup_identities
  render_secret | kubectl create -f - >/dev/null
  echo "created secret $NAMESPACE/$SECRET (values are not shown)"
  if kube get statefulset "$STATEFULSET" >/dev/null 2>&1; then
    echo "SeaweedFS is already deployed; restart it to load the credentials:"
    echo "  kubectl -n $NAMESPACE rollout restart statefulset/$STATEFULSET"
  fi
}

cmd_rotate() {
  [[ "${1:-}" == "--yes" ]] || die "rotate invalidates the current keys for every client; re-run with --yes"
  preflight
  secret_exists "$NAMESPACE" "$SECRET" || die "secret $NAMESPACE/$SECRET not found; use 'create'"
  generate_admin_identity
  generate_backup_identities
  render_secret | kubectl replace -f - >/dev/null
  echo "replaced secret $NAMESPACE/$SECRET (values are not shown)"
  restart_seaweedfs
  sync_backup_secrets
  echo "update every client that copied the old admin keys"
}

cmd_backup_identities() {
  [[ "${1:-}" == "--yes" ]] || die "this replaces the backup and restore keys and restarts SeaweedFS; re-run with --yes"
  preflight
  secret_exists "$NAMESPACE" "$SECRET" || die "secret $NAMESPACE/$SECRET not found; use 'create'"
  ADMIN_AK=$(read_key AWS_ACCESS_KEY_ID)
  ADMIN_SK=$(read_key AWS_SECRET_ACCESS_KEY)
  generate_backup_identities
  render_secret | kubectl replace -f - >/dev/null
  echo "replaced secret $NAMESPACE/$SECRET with new backup and restore keys; admin keys are unchanged (values are not shown)"
  restart_seaweedfs
  sync_backup_secrets
}

cmd_sync_backup() {
  preflight
  secret_exists "$NAMESPACE" "$SECRET" || die "secret $NAMESPACE/$SECRET not found"
  sync_backup_secrets
}

fingerprint() {
  kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}" | openssl base64 -d -A | sha256sum | cut -c1-12
}

cmd_status() {
  preflight
  secret_exists "$NAMESPACE" "$SECRET" || die "secret $NAMESPACE/$SECRET not found"
  kube get secret "$SECRET" -o go-template='created:      {{.metadata.creationTimestamp}}
generated-at: {{index .metadata.annotations "object-storage.homelab/generated-at"}}
keys:        {{range $k, $v := .data}} {{$k}}{{end}}
'
  echo "identities:   $(read_key 's3\.json' | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | paste -sd' ')"
  echo "admin   access key sha256: $(fingerprint "$NAMESPACE" "$SECRET" AWS_ACCESS_KEY_ID)"
  if [[ -n "$(read_key BACKUP_ACCESS_KEY_ID)" ]]; then
    echo "backup  access key sha256: $(fingerprint "$NAMESPACE" "$SECRET" BACKUP_ACCESS_KEY_ID)"
    echo "restore access key sha256: $(fingerprint "$NAMESPACE" "$SECRET" RESTORE_ACCESS_KEY_ID)"
  fi
  for name in "$BACKUP_SECRET" "$RESTORE_SECRET"; do
    if secret_exists "$BACKUP_NAMESPACE" "$name"; then
      echo "$BACKUP_NAMESPACE/$name access key sha256: $(fingerprint "$BACKUP_NAMESPACE" "$name" AWS_ACCESS_KEY_ID)"
    else
      echo "$BACKUP_NAMESPACE/$name: not found"
    fi
  done
}

case "${1:-}" in
  create) cmd_create ;;
  rotate) shift; cmd_rotate "$@" ;;
  backup-identities) shift; cmd_backup_identities "$@" ;;
  sync-backup) cmd_sync_backup ;;
  status) cmd_status ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac

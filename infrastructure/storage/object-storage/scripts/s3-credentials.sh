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
KFP_NAMESPACE="kubeflow"
KFP_SECRET="mlpipeline-minio-artifact"
KFP_BUCKET="mlpipeline"

IDENTITIES=(admin backup restore kfp)
declare -A PREFIX=([admin]="" [backup]="BACKUP_" [restore]="RESTORE_" [kfp]="KFP_")
declare -A ACTIONS=(
  [admin]='"Admin","Read","List","Tagging","Write"'
  [backup]='"Read","List"'
  [restore]='"Admin:restore-*"'
  [kfp]="\"Read:${KFP_BUCKET}\",\"Write:${KFP_BUCKET}\",\"List:${KFP_BUCKET}\""
)
declare -A AK=() SK=()

usage() {
  cat <<'USAGE'
Usage: s3-credentials.sh <command>

Commands:
  create                Generate new S3 credentials and create the Secret (fails if it already exists)
  rotate --yes          Replace every credential and restart SeaweedFS (old keys stop working)
  backup-identities --yes
                        Generate the read-only "backup" and the "restore" (restore-* buckets only)
                        identities, keep the other keys, restart SeaweedFS and sync the backup Secrets
  kfp-identity --yes    Generate the "kfp" identity (mlpipeline bucket only), keep the other keys,
                        restart SeaweedFS and sync kubeflow/mlpipeline-minio-artifact
  sync                  Copy the client keys into the object-storage-backup and kubeflow namespaces
  sync-backup           Same as sync (kept for compatibility)
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

<<<<<<< HEAD
load_identities() {
  local id
  for id in "${IDENTITIES[@]}"; do
    AK[$id]=$(read_key "$(data_key "$id" ACCESS_KEY_ID)")
    SK[$id]=$(read_key "$(data_key "$id" SECRET_ACCESS_KEY)")
  done
  [[ -n "${AK[admin]}" && -n "${SK[admin]}" ]] || die "secret $NAMESPACE/$SECRET has no admin keys"
}

generate() {
  local id
  for id in "$@"; do
    AK[$id]=$(openssl rand -hex 10 | tr 'a-f' 'A-F')
    SK[$id]=$(openssl rand -base64 30)
  done
}

data_key() {
  if [[ -z "${PREFIX[$1]}" ]]; then
    printf 'AWS_%s' "$2"
  else
    printf '%s%s' "${PREFIX[$1]}" "$2"
  fi
}

render_secret() {
  local id identities="" now
  for id in "${IDENTITIES[@]}"; do
    [[ -n "${AK[$id]:-}" ]] || continue
    [[ ${#AK[$id]} -eq 20 && ${#SK[$id]} -eq 40 ]] || die "invalid key length for identity $id"
    identities+="${identities:+,}$(printf '{"name":"%s","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":[%s]}' \
      "$id" "${AK[$id]}" "${SK[$id]}" "${ACTIONS[$id]}")"
  done
=======
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
>>>>>>> 9ac606329cd6495688b162a66d4cbb239208ac6b
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
<<<<<<< HEAD
    object-storage.homelab/identity: "$(for id in "${IDENTITIES[@]}"; do [[ -n "${AK[$id]:-}" ]] && printf '%s,' "$id"; done | sed 's/,$//')"
data:
  s3.json: $(b64 "{\"identities\":[${identities}]}")
YAML
  for id in "${IDENTITIES[@]}"; do
    [[ -n "${AK[$id]:-}" ]] || continue
    echo "  $(data_key "$id" ACCESS_KEY_ID): $(b64 "${AK[$id]}")"
    echo "  $(data_key "$id" SECRET_ACCESS_KEY): $(b64 "${SK[$id]}")"
  done
}

render_client_secret() {
  local name=$1 namespace=$2 identity=$3 part_of=$4 access_name=$5 secret_name=$6
=======
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
>>>>>>> 9ac606329cd6495688b162a66d4cbb239208ac6b
  cat <<YAML
apiVersion: v1
kind: Secret
type: Opaque
metadata:
<<<<<<< HEAD
  name: ${name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/part-of: ${part_of}
  annotations:
    object-storage.homelab/identity: "${identity}"
    object-storage.homelab/source: "${NAMESPACE}/${SECRET}"
data:
  ${access_name}: $(b64 "${AK[$identity]}")
  ${secret_name}: $(b64 "${SK[$identity]}")
=======
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
>>>>>>> 9ac606329cd6495688b162a66d4cbb239208ac6b
YAML
}

upsert() {
  if secret_exists "$1" "$2"; then
    kubectl replace -f - >/dev/null
  else
    kubectl create -f - >/dev/null
  fi
}

<<<<<<< HEAD
=======
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

>>>>>>> 9ac606329cd6495688b162a66d4cbb239208ac6b
restart_seaweedfs() {
  if kube get statefulset "$STATEFULSET" >/dev/null 2>&1; then
    kube rollout restart "statefulset/$STATEFULSET"
    kube rollout status "statefulset/$STATEFULSET" --timeout=300s
  fi
}

<<<<<<< HEAD
sync_client() {
  local identity=$1 name=$2 namespace=$3 part_of=$4 access_name=$5 secret_name=$6
  if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
    echo "namespace $namespace not found; skipped $identity (run 'sync' after creating it)"
    return
  fi
  if [[ -z "${AK[$identity]:-}" ]]; then
    echo "identity $identity not found in $NAMESPACE/$SECRET; skipped $namespace/$name"
    return
  fi
  render_client_secret "$name" "$namespace" "$identity" "$part_of" "$access_name" "$secret_name" | upsert "$namespace" "$name"
  echo "synced secret $namespace/$name from identity $identity (values are not shown)"
}

sync_all() {
  sync_client backup "$BACKUP_SECRET" "$BACKUP_NAMESPACE" object-storage-backup AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  sync_client restore "$RESTORE_SECRET" "$BACKUP_NAMESPACE" object-storage-backup AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  sync_client kfp "$KFP_SECRET" "$KFP_NAMESPACE" kubeflow-pipelines accesskey secretkey
}

replace_and_restart() {
  render_secret | kubectl replace -f - >/dev/null
  echo "replaced secret $NAMESPACE/$SECRET; regenerated: $* (values are not shown)"
  restart_seaweedfs
  sync_all
=======
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
>>>>>>> 9ac606329cd6495688b162a66d4cbb239208ac6b
}

cmd_create() {
  preflight
  secret_exists "$NAMESPACE" "$SECRET" && die "secret $NAMESPACE/$SECRET already exists; use 'rotate --yes' to replace it"
<<<<<<< HEAD
  generate "${IDENTITIES[@]}"
=======
  generate_admin_identity
  generate_backup_identities
>>>>>>> 9ac606329cd6495688b162a66d4cbb239208ac6b
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
<<<<<<< HEAD
  generate "${IDENTITIES[@]}"
  replace_and_restart "${IDENTITIES[@]}"
  echo "update every client that copied the old admin keys"
}

cmd_regenerate() {
  local confirm=$1
  shift
  [[ "$confirm" == "--yes" ]] || die "this replaces the keys of: $* and restarts SeaweedFS; re-run with --yes"
  preflight
  secret_exists "$NAMESPACE" "$SECRET" || die "secret $NAMESPACE/$SECRET not found; use 'create'"
  load_identities
  generate "$@"
  replace_and_restart "$@"
}

cmd_sync() {
  preflight
  secret_exists "$NAMESPACE" "$SECRET" || die "secret $NAMESPACE/$SECRET not found"
  load_identities
  sync_all
=======
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
>>>>>>> 9ac606329cd6495688b162a66d4cbb239208ac6b
}

fingerprint() {
  kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}" | openssl base64 -d -A | sha256sum | cut -c1-12
}

cmd_status() {
  local id
  preflight
  secret_exists "$NAMESPACE" "$SECRET" || die "secret $NAMESPACE/$SECRET not found"
  kube get secret "$SECRET" -o go-template='created:      {{.metadata.creationTimestamp}}
generated-at: {{index .metadata.annotations "object-storage.homelab/generated-at"}}
keys:        {{range $k, $v := .data}} {{$k}}{{end}}
'
  echo "identities:   $(read_key 's3\.json' | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | paste -sd' ')"
<<<<<<< HEAD
  for id in "${IDENTITIES[@]}"; do
    if [[ -n "$(read_key "$(data_key "$id" ACCESS_KEY_ID)")" ]]; then
      printf '%-8s access key sha256: %s\n' "$id" "$(fingerprint "$NAMESPACE" "$SECRET" "$(data_key "$id" ACCESS_KEY_ID)")"
    fi
  done
  for target in "$BACKUP_NAMESPACE/$BACKUP_SECRET/AWS_ACCESS_KEY_ID" "$BACKUP_NAMESPACE/$RESTORE_SECRET/AWS_ACCESS_KEY_ID" "$KFP_NAMESPACE/$KFP_SECRET/accesskey"; do
    IFS=/ read -r ns name key <<<"$target"
    if secret_exists "$ns" "$name"; then
      echo "$ns/$name access key sha256: $(fingerprint "$ns" "$name" "$key")"
    else
      echo "$ns/$name: not found"
=======
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
>>>>>>> 9ac606329cd6495688b162a66d4cbb239208ac6b
    fi
  done
}

case "${1:-}" in
  create) cmd_create ;;
  rotate) shift; cmd_rotate "$@" ;;
<<<<<<< HEAD
  backup-identities) shift; cmd_regenerate "${1:-}" backup restore ;;
  kfp-identity) shift; cmd_regenerate "${1:-}" kfp ;;
  sync|sync-backup) cmd_sync ;;
=======
  backup-identities) shift; cmd_backup_identities "$@" ;;
  sync-backup) cmd_sync_backup ;;
>>>>>>> 9ac606329cd6495688b162a66d4cbb239208ac6b
  status) cmd_status ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac

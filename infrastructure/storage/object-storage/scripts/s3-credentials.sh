#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

NAMESPACE="object-storage"
SECRET="seaweedfs-s3-credentials"
STATEFULSET="seaweedfs"
IDENTITY="admin"
ACTIONS='"Admin","Read","List","Tagging","Write"'

usage() {
  cat <<'USAGE'
Usage: s3-credentials.sh <command>

Commands:
  create        Generate new S3 credentials and create the Secret (fails if it already exists)
  rotate --yes  Replace the credentials and restart SeaweedFS (old keys stop working)
  status        Show Secret metadata and key fingerprints without revealing any value
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
  kube get secret "$SECRET" >/dev/null 2>&1
}

render_secret() {
  local access_key secret_key s3_json now
  access_key=$(openssl rand -hex 10 | tr 'a-f' 'A-F')
  secret_key=$(openssl rand -base64 30)
  [[ ${#access_key} -eq 20 && ${#secret_key} -eq 40 ]] || die "key generation failed"
  s3_json=$(printf '{"identities":[{"name":"%s","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":[%s]}]}' \
    "$IDENTITY" "$access_key" "$secret_key" "$ACTIONS")
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cat <<EOF
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
    object-storage.homelab/identity: "${IDENTITY}"
data:
  s3.json: $(b64 "$s3_json")
  AWS_ACCESS_KEY_ID: $(b64 "$access_key")
  AWS_SECRET_ACCESS_KEY: $(b64 "$secret_key")
EOF
}

fingerprint() {
  kube get secret "$SECRET" -o "jsonpath={.data.$1}" | openssl base64 -d -A | sha256sum | cut -c1-12
}

cmd_create() {
  preflight
  secret_exists && die "secret $NAMESPACE/$SECRET already exists; use 'rotate --yes' to replace it"
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
  secret_exists || die "secret $NAMESPACE/$SECRET not found; use 'create'"
  render_secret | kubectl replace -f - >/dev/null
  echo "replaced secret $NAMESPACE/$SECRET (values are not shown)"
  if kube get statefulset "$STATEFULSET" >/dev/null 2>&1; then
    kube rollout restart "statefulset/$STATEFULSET"
    kube rollout status "statefulset/$STATEFULSET" --timeout=300s
  fi
  echo "update every client that copied the old keys"
}

cmd_status() {
  preflight
  secret_exists || die "secret $NAMESPACE/$SECRET not found"
  kube get secret "$SECRET" -o go-template='created:      {{.metadata.creationTimestamp}}
generated-at: {{index .metadata.annotations "object-storage.homelab/generated-at"}}
keys:        {{range $k, $v := .data}} {{$k}}{{end}}
'
  echo "identities:   $(kube get secret "$SECRET" -o 'jsonpath={.data.s3\.json}' | openssl base64 -d -A | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | paste -sd' ')"
  echo "access key sha256: $(fingerprint AWS_ACCESS_KEY_ID)"
  echo "secret key sha256: $(fingerprint AWS_SECRET_ACCESS_KEY)"
}

case "${1:-}" in
  create) cmd_create ;;
  rotate) shift; cmd_rotate "$@" ;;
  status) cmd_status ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac

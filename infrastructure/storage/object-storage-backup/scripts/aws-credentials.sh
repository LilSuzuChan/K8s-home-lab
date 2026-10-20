#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

NAMESPACE="object-storage-backup"
STACK="HomelabBackupStack"
REGION="ap-northeast-1"
WRITER_SECRET="aws-backup-writer"
READER_SECRET="aws-backup-reader"

usage() {
  cat <<'USAGE'
Usage: aws-credentials.sh <command>

Copies the backup IAM access keys that CDK stored in AWS Secrets Manager into Kubernetes Secrets.
Requires an AWS CLI session of an operator (for example "aws sso login") and kubectl access.

Commands:
  import        Create the aws-backup-writer and aws-backup-reader Secrets (fails if they exist)
  rotate --yes  Replace both Secrets with the current values in Secrets Manager
  status        Compare the Kubernetes Secrets with the active IAM access keys without revealing values
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

preflight() {
  command -v aws >/dev/null || die "aws CLI not found"
  command -v kubectl >/dev/null || die "kubectl not found"
  command -v python3 >/dev/null || die "python3 not found"
  command -v openssl >/dev/null || die "openssl not found"
  echo "aws:     $(aws sts get-caller-identity --query Arn --output text)"
  echo "context: $(kubectl config current-context)"
  echo "server:  $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  kubectl get namespace "$NAMESPACE" >/dev/null || die "namespace $NAMESPACE not found (apply object-storage-backup/ first)"
}

stack_output() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

secret_exists() {
  kubectl -n "$NAMESPACE" get secret "$1" >/dev/null 2>&1
}

render_secret() {
  python3 -c '
import base64, json, re, sys
name, namespace, source, bucket = sys.argv[1:5]
value = json.load(sys.stdin)
key_id, secret = value["AWS_ACCESS_KEY_ID"], value["AWS_SECRET_ACCESS_KEY"]
if not re.fullmatch(r"AKIA[A-Z0-9]{16}", key_id) or len(secret) != 40:
    sys.exit("unexpected secret format in " + source)
if not re.fullmatch(r"homelab-seaweedfs-backup-[0-9]{12}-ap-northeast-1", bucket):
    sys.exit("unexpected bucket name")
b64 = lambda s: base64.b64encode(s.encode()).decode()
print(f"""apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: {name}
  namespace: {namespace}
  labels:
    app.kubernetes.io/name: seaweedfs-backup
    app.kubernetes.io/part-of: object-storage-backup
  annotations:
    object-storage.homelab/source: "aws-secretsmanager:{source}"
data:
  AWS_ACCESS_KEY_ID: {b64(key_id)}
  AWS_SECRET_ACCESS_KEY: {b64(secret)}
  BACKUP_BUCKET: {b64(bucket)}""")
' "$@"
}

copy_secret() {
  local name=$1 source=$2 verb=$3 bucket
  bucket=$(stack_output BucketName)
  [[ -n "$bucket" && "$bucket" != "None" ]] || die "stack $STACK has no BucketName output"
  aws secretsmanager get-secret-value --region "$REGION" --secret-id "$source" --query SecretString --output text \
    | render_secret "$name" "$NAMESPACE" "$source" "$bucket" \
    | kubectl "$verb" -f - >/dev/null
  echo "${verb}d secret $NAMESPACE/$name from $source (values are not shown)"
}

cmd_import() {
  preflight
  for name in "$WRITER_SECRET" "$READER_SECRET"; do
    secret_exists "$name" && die "secret $NAMESPACE/$name already exists; use 'rotate --yes'"
  done
  copy_secret "$WRITER_SECRET" "$(stack_output WriterSecretName)" create
  copy_secret "$READER_SECRET" "$(stack_output ReaderSecretName)" create
}

cmd_rotate() {
  [[ "${1:-}" == "--yes" ]] || die "rotate replaces the Kubernetes Secrets; re-run with --yes"
  preflight
  copy_secret "$WRITER_SECRET" "$(stack_output WriterSecretName)" replace
  copy_secret "$READER_SECRET" "$(stack_output ReaderSecretName)" replace
}

cmd_status() {
  preflight
  for pair in "$WRITER_SECRET:homelab-backup-writer" "$READER_SECRET:homelab-backup-reader"; do
    local name=${pair%%:*} user=${pair#*:} current active
    if ! secret_exists "$name"; then
      echo "$NAMESPACE/$name: not found"
      continue
    fi
    current=$(kubectl -n "$NAMESPACE" get secret "$name" -o 'jsonpath={.data.AWS_ACCESS_KEY_ID}' | openssl base64 -d -A | sha256sum | cut -c1-12)
    active=$(aws iam list-access-keys --user-name "$user" --query "AccessKeyMetadata[?Status=='Active'].AccessKeyId" --output text \
      | tr '\t' '\n' | while read -r id; do printf '%s' "$id" | sha256sum | cut -c1-12; done | paste -sd' ')
    if [[ " $active " == *" $current "* ]]; then
      echo "$NAMESPACE/$name: access key sha256 $current matches an active key of $user"
    else
      echo "$NAMESPACE/$name: access key sha256 $current does NOT match the active keys of $user ($active)"
    fi
  done
}

case "${1:-}" in
  import) cmd_import ;;
  rotate) shift; cmd_rotate "$@" ;;
  status) cmd_status ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac

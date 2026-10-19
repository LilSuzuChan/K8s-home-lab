#!/bin/sh
set -eu

mode="${1:?usage: s3-access.sh allowed|denied}"
host="seaweedfs.object-storage.svc.cluster.local"
endpoint="http://$host:8333"

log() {
  echo "[$mode] $*"
}

fail() {
  echo "[$mode] FAIL: $*" >&2
  exit 1
}

http_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"
}

address=$(getent hosts "$host" | awk '{print $1}')
[ -n "$address" ] || fail "cannot resolve $host"
log "DNS $host -> $address"

case "$mode" in
  allowed)
    code=$(http_code "$endpoint/healthz")
    [ "$code" = "200" ] || fail "GET /healthz returned $code, expected 200"
    log "GET /healthz -> $code"
    code=$(http_code "$endpoint/")
    [ "$code" = "403" ] || fail "anonymous ListBuckets returned $code, expected 403"
    log "anonymous ListBuckets -> $code"
    code=$(http_code -X PUT "$endpoint/anonymous-create-must-fail")
    [ "$code" = "403" ] || fail "anonymous CreateBucket returned $code, expected 403"
    log "anonymous CreateBucket -> $code"
    wrong_key=$(od -An -tx1 -N10 /dev/urandom | tr -d ' \n' | tr 'a-f' 'A-F')
    wrong_secret=$(od -An -tx1 -N20 /dev/urandom | tr -d ' \n')
    if AWS_ACCESS_KEY_ID="$wrong_key" AWS_SECRET_ACCESS_KEY="$wrong_secret" \
      aws --endpoint-url "$endpoint" s3 ls >/tmp/wrong.log 2>&1; then
      fail "request with unknown credentials succeeded"
    fi
    code=$(grep -o '(InvalidAccessKeyId)\|(AccessDenied)\|(SignatureDoesNotMatch)' /tmp/wrong.log | head -n1)
    [ -n "$code" ] || fail "unknown credentials failed with an unexpected error"
    log "unknown credentials rejected $code"
    ;;
  denied)
    if curl -s -o /dev/null --max-time 5 "$endpoint/healthz"; then
      fail "S3 endpoint is reachable from a namespace without the s3-client label"
    else
      log "connection blocked by NetworkPolicy (curl exit $?)"
    fi
    ;;
  *)
    fail "unknown mode"
    ;;
esac

log "PASS"

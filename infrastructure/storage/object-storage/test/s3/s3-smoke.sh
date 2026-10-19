#!/bin/sh
set -eu

mode="${1:?usage: s3-smoke.sh write|verify|cleanup}"
bucket="${TEST_BUCKET:-s3-smoke-test}"
key="smoke/random.bin"
work=$(mktemp -d)

log() {
  echo "[$mode] $*"
}

fail() {
  echo "[$mode] FAIL: $*" >&2
  exit 1
}

download_and_compare() {
  aws s3 cp --only-show-errors "s3://$bucket/$key" "$work/downloaded.bin"
  aws s3 cp --only-show-errors "s3://$bucket/$key.sha256" "$work/expected.sha256"
  expected=$(cat "$work/expected.sha256")
  actual=$(sha256sum "$work/downloaded.bin" | cut -d' ' -f1)
  [ "$actual" = "$expected" ] || fail "sha256 mismatch: expected=$expected actual=$actual"
  log "downloaded $key sha256=$actual (matches)"
}

host=$(echo "$AWS_ENDPOINT_URL" | sed -E 's#^[a-z]+://([^:/]+).*#\1#')
address=$(getent hosts "$host" | awk '{print $1}')
[ -n "$address" ] || fail "cannot resolve $host"
log "DNS $host -> $address"

case "$mode" in
  write)
    if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
      fail "bucket $bucket already exists; run cleanup first"
    fi
    aws s3api create-bucket --bucket "$bucket" >/dev/null
    log "created bucket $bucket"
    dd if=/dev/urandom of="$work/random.bin" bs=1M count=5 2>/dev/null
    sha256sum "$work/random.bin" | cut -d' ' -f1 > "$work/random.bin.sha256"
    aws s3 cp --only-show-errors "$work/random.bin" "s3://$bucket/$key"
    aws s3 cp --only-show-errors "$work/random.bin.sha256" "s3://$bucket/$key.sha256"
    log "uploaded $key sha256=$(cat "$work/random.bin.sha256")"
    download_and_compare
    wrong_secret=$(od -An -tx1 -N20 /dev/urandom | tr -d ' \n')
    if AWS_SECRET_ACCESS_KEY="$wrong_secret" aws s3 ls >"$work/wrong.log" 2>&1; then
      fail "request with a wrong secret key succeeded"
    fi
    code=$(grep -o '(SignatureDoesNotMatch)\|(AccessDenied)\|(InvalidAccessKeyId)' "$work/wrong.log" | head -n1)
    [ -n "$code" ] || fail "wrong secret key failed with an unexpected error"
    log "wrong secret key rejected $code"
    ;;
  verify)
    download_and_compare
    aws s3 ls "s3://$bucket/smoke/"
    ;;
  cleanup)
    aws s3 rm --only-show-errors --recursive "s3://$bucket"
    aws s3api delete-bucket --bucket "$bucket"
    if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
      fail "bucket $bucket still exists"
    fi
    log "deleted bucket $bucket"
    ;;
  *)
    fail "unknown mode"
    ;;
esac

log "PASS"

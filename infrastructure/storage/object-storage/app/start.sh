#!/bin/sh
set -eu

config="${SEAWEEDFS_S3_CONFIG:-/etc/seaweedfs/s3/s3.json}"

fail() {
  echo "start.sh: $*" >&2
  exit 1
}

[ -f "$config" ] || fail "S3 config $config not found"
[ -s "$config" ] || fail "S3 config $config is empty"
grep -q '"accessKey"' "$config" || fail "S3 config $config has no accessKey"
grep -q '"secretKey"' "$config" || fail "S3 config $config has no secretKey"
if grep -Eq '"name"[[:space:]]*:[[:space:]]*"anonymous"' "$config"; then
  fail "S3 config $config defines the anonymous identity"
fi

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

exec "${SEAWEEDFS_ENTRYPOINT:-/entrypoint.sh}" server \
  -dir="${SEAWEEDFS_DATA_DIR:-/data}" \
  -ip=127.0.0.1 \
  -s3.ip.bind="${SEAWEEDFS_S3_BIND:-0.0.0.0}" \
  -filer \
  -s3 \
  -s3.config="$config" \
  -s3.port.iceberg=0 \
  -s3.port.lance=0 \
  -master.volumeSizeLimitMB=1024 \
  -master.volumePreallocate=false \
  -master.telemetry=false \
  -volume.max=0 \
  -volume.minFreeSpace="${SEAWEEDFS_MIN_FREE_SPACE:-20GiB}"

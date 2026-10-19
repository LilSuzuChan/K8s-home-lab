#!/bin/sh
set -eu

host="${SEAWEEDFS_PROBE_HOST:-127.0.0.1}"

for endpoint in "$host:9333" "$host:8080" "$host:8888" "$host:8333"; do
  wget -q -T 3 -O /dev/null "http://$endpoint/readyz"
done

status=$(wget -S -T 3 -O /dev/null "http://$host:8333/" 2>&1 | awk '/^ *HTTP\//{code=$2} END{print code}')
if [ "$status" != "403" ]; then
  echo "ready.sh: anonymous request returned '$status', expected 403" >&2
  exit 1
fi

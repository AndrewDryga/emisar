#!/usr/bin/env bash
set -euo pipefail

# The vendor initializer's --shutdown returns before its server releases the
# port. Seed the authenticated final server instead of overlapping two boots.
rm -f /tmp/packtest-seeded
docker-entrypoint.sh mongod --auth --bind_ip_all --setParameter enableTestCommands=1 &
mongodb_pid=$!
trap 'kill -TERM "$mongodb_pid" 2>/dev/null || true; wait "$mongodb_pid" || true' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

ready=false
for ((attempt = 0; attempt < 12; attempt++)); do
  kill -0 "$mongodb_pid"
  if timeout 5s mongosh --host 127.0.0.1 --quiet --eval 'db.adminCommand("ping")' >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 5
done
if [[ $ready != true ]]; then
  echo 'MongoDB did not become ready for fixture seeding' >&2
  exit 1
fi

timeout 30s mongosh --host 127.0.0.1 --quiet /fixture/init.js
touch /tmp/packtest-seeded
wait "$mongodb_pid"

#!/bin/sh
set -eu

host=$1
port=$2
timeout=$3

if detail=$(nc -z -v -w "$timeout" "$host" "$port" 2>&1); then
  printf 'reachable=true\nhost=%s\nport=%s\n' "$host" "$port"
else
  printf '%s\n' "$detail" >&2
  printf 'reachable=false\nhost=%s\nport=%s\n' "$host" "$port" >&2
  exit 1
fi

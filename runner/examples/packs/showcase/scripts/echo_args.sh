#!/usr/bin/env bash
# Trivial demo script: print a message N times.
set -euo pipefail

message=""
repeat=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --message) message="$2"; shift 2;;
    --repeat)  repeat="$2";  shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

for ((i=0; i<repeat; i++)); do
  printf '%s\n' "$message"
done

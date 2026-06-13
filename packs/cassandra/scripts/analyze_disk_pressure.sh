#!/usr/bin/env bash
# Read-only Cassandra disk-pressure analyser.
#
# This script is packaged with the cassandra pack. emisar loads it from disk
# at runner start; runtime callers cannot supply script content. It is
# intentionally simple — output is meant to be read by humans (or LLMs).

set -euo pipefail

keyspace_filter=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keyspace-filter)
      keyspace_filter="$2"
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

echo "== filesystem usage =="
df -P -h /var/lib/cassandra /var/log/cassandra 2>/dev/null || df -P -h /

echo
echo "== cassandra data tree (top-level sizes) =="
if [[ -d /var/lib/cassandra/data ]]; then
  du -sh /var/lib/cassandra/data/* 2>/dev/null | sort -h | tail -20
else
  echo "(no /var/lib/cassandra/data on this host)"
fi

if [[ -n "$keyspace_filter" && -d "/var/lib/cassandra/data/${keyspace_filter}" ]]; then
  echo
  echo "== keyspace ${keyspace_filter} tables =="
  du -sh "/var/lib/cassandra/data/${keyspace_filter}"/* 2>/dev/null | sort -h | tail -20
fi

echo
echo "== commitlog usage =="
if [[ -d /var/lib/cassandra/commitlog ]]; then
  du -sh /var/lib/cassandra/commitlog 2>/dev/null
else
  echo "(no /var/lib/cassandra/commitlog on this host)"
fi

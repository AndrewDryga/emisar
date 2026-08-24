#!/bin/sh
set -u

if [ "${1:-}" = "--cluster" ] && [ "${2:-}" = "check" ]; then
	printf '%s\n' "$*" >/tmp/packtest-redis-cluster-check-argv
	printf 'PACKTEST_REDIS_CLUSTER_TARGET %s\n' "${3:-}"
	exit 0
fi

if [ "${1:-}" = "-p" ] && [ "${2:-}" = "26379" ] &&
	[ "${3:-}" = "SENTINEL" ] && [ "${4:-}" = "IS-MASTER-DOWN-BY-ADDR" ]; then
	printf '%s\n' "$*" >>/tmp/packtest-redis-sentinel-argv
fi

exec /usr/bin/redis-cli "$@"

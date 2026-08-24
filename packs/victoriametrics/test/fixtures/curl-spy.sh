#!/bin/sh
set -eu

for argument in "$@"; do
	case "$argument" in
	http://cost-canary/*)
		printf '%s\n' "$*" >/tmp/packtest-victoriametrics-cost-argv
		printf '{"status":"success","data":{"resultType":"matrix","result":[],"PACKTEST_VM_COST_CANARY":true}}\n'
		exit 0
		;;
	esac
done

exec /usr/bin/curl "$@"

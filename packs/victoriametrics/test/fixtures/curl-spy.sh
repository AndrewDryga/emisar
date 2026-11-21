#!/bin/sh
# Stands in for curl on the runner. A pack call reads its config document from
# stdin; the spy records that call's argv and config so a probe can show where
# the URL and credentials travelled, answers the cost canary itself, and hands
# everything else to the real curl.
set -eu

case " $* " in
*" --config - "*) ;;
*) exec /usr/bin/curl "$@" ;;
esac

config=$(cat)
printf '%s\n' "$*" >>/tmp/packtest-victoriametrics-argv
printf '%s\n' "$config" >>/tmp/packtest-victoriametrics-config

case "$config" in
*'@cost-canary/'*)
	printf '%s\n' "$*" >/tmp/packtest-victoriametrics-cost-argv
	printf '{"status":"success","data":{"resultType":"matrix","result":[],"PACKTEST_VM_COST_CANARY":true}}\n'
	exit 0
	;;
esac

printf '%s\n' "$config" | exec /usr/bin/curl "$@"

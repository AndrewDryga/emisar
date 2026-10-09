#!/bin/sh
set -eu

# Observe the fixed target and non-voting arguments without replacing vendor
# behavior. Both forms keep this spy useful for the pre-fix negative control.
case "$*" in
--cluster\ check\ *|-e\ --cluster\ check\ *)
	printf '%s\n' "$*" >/tmp/packtest-redis-cluster-check-argv
	;;
-p\ 26379\ SENTINEL\ IS-MASTER-DOWN-BY-ADDR\ *|-e\ -p\ 26379\ SENTINEL\ IS-MASTER-DOWN-BY-ADDR\ *)
	printf '%s\n' "$*" >>/tmp/packtest-redis-sentinel-argv
	;;
esac

exec /usr/bin/redis-cli "$@"

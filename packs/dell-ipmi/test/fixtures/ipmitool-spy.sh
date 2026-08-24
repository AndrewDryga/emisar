#!/bin/sh
set -u

for argument in "$@"; do
	if [ "$argument" = "blocked-bmc" ]; then
		printf 'PACKTEST_CLIENT_INVOKED ipmitool blocked-bmc\n' >&2
		: >/tmp/packtest-ipmi-client-invoked
		printf 'System Power : on\n'
		exit 0
	fi
done

printf '%s\n' "$*" >/tmp/packtest-ipmitool-argv
printf 'System Power : on\n'

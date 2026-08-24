#!/bin/sh
set -u

for argument in "$@"; do
	if [ "$argument" = "blocked-target" ] || [ "$argument" = "snmpd:161" ]; then
		printf 'PACKTEST_CLIENT_INVOKED snmpbulkwalk %s\n' "$argument" >&2
		: >/tmp/packtest-snmp-client-invoked
		printf 'blocked fixture response\n'
		exit 0
	fi
done

exec /usr/bin/snmpbulkwalk "$@"

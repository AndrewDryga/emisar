#!/bin/sh
# snmpreq.sh — packaged with the "snmp" emisar pack. emisar loads it from disk
# when the pack is trusted, journals its SHA-256 with every run, and runs it via
# the interpreter named in each action. It is never fetched or assembled at
# request time.
#
# One read against an SNMP agent using the net-snmp CLI. Arguments:
#
#   $1     net-snmp tool: snmpget or snmpbulkwalk.
#   $2     target host[:port] (the action's {{ args.host }}, schema-bounded).
#   $3...  one or more numeric OIDs — fixed in the action for the curated
#          reads, or a bounded {{ args.oid }} for the generic get / walk.
#
# Credentials come from the environment and are written to a transient
# snmp.conf that net-snmp reads via $SNMPCONFPATH, so the community string and
# the v3 passphrases never enter argv, a `ps` listing, or the audit log. The
# directory is 0700 (mktemp) and removed on exit, including on the executor's
# SIGTERM (it signals the whole process group, so this shell's trap runs).
#
#   SNMP_VERSION    1, 2c (default), or 3.
#   v1/v2c: SNMP_COMMUNITY   the read-only community string.
#   v3:     SNMP_USER, SNMP_LEVEL (noAuthNoPriv|authNoPriv|authPriv, default
#           authPriv), SNMP_AUTH_PROTO (default SHA) + SNMP_AUTH_PASS,
#           SNMP_PRIV_PROTO (default AES) + SNMP_PRIV_PASS.
set -u

tool=$1
host=$2
shift 2

conf=$(mktemp -d)
trap 'rm -rf "$conf"' EXIT INT TERM

if [ "${SNMP_VERSION:-2c}" = "3" ]; then
	{
		printf 'defVersion 3\n'
		printf 'defSecurityLevel %s\n' "${SNMP_LEVEL:-authPriv}"
		printf 'defSecurityName %s\n' "${SNMP_USER:-}"
		printf 'defAuthType %s\n' "${SNMP_AUTH_PROTO:-SHA}"
		printf 'defPrivType %s\n' "${SNMP_PRIV_PROTO:-AES}"
		if [ -n "${SNMP_AUTH_PASS:-}" ]; then printf 'defAuthPassphrase %s\n' "$SNMP_AUTH_PASS"; fi
		if [ -n "${SNMP_PRIV_PASS:-}" ]; then printf 'defPrivPassphrase %s\n' "$SNMP_PRIV_PASS"; fi
	} >"$conf/snmp.conf"
elif [ -n "${SNMP_COMMUNITY:-}" ]; then
	{
		printf 'defVersion %s\n' "${SNMP_VERSION:-2c}"
		printf 'defCommunity %s\n' "$SNMP_COMMUNITY"
	} >"$conf/snmp.conf"
else
	echo "snmp: set SNMP_COMMUNITY (v1/v2c) or SNMP_VERSION=3 with SNMP_USER + passphrases" >&2
	exit 1
fi

SNMPCONFPATH=$conf
export SNMPCONFPATH
"$tool" "$host" "$@"

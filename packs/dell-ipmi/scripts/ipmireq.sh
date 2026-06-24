#!/bin/sh
# ipmireq.sh — packaged with the "dell-ipmi" emisar pack. emisar loads it from
# disk when the pack is trusted, journals its SHA-256 with every run, and runs
# it via the interpreter named in each action. It is never fetched or assembled
# at request time.
#
# One out-of-band IPMI 2.0 (RMCP+ / lanplus) call against a BMC — a Dell iDRAC
# or any IPMI-over-LAN baseboard controller. Arguments:
#
#   $1     target BMC hostname or IP (the action's {{ args.host }}, bounded by
#          the action's validation.pattern).
#   $2...  the ipmitool subcommand and its fixed / enum args from the action
#          (e.g. "sdr" "elist", or "chassis" "power" "status"). The subcommand
#          is authored in the action YAML, never free-form from the cloud.
#
# Credentials come from the runner environment and never enter argv, a `ps`
# listing, or the audit log:
#   IPMI_USER       BMC account name (-U). Not itself a secret, but kept in the
#                   environment so the pack carries no identity.
#   IPMI_PASSWORD   BMC password — read by ipmitool's -E directly from the
#                   environment. We never pass -P, which would expose it in argv.
#   IPMI_CIPHER     RMCP+ cipher suite (-C); default 3 (RAKP-HMAC-SHA1 +
#                   AES-128-CBC), the reliable Dell baseline. ipmitool's own
#                   default changed 3->17 in 1.8.19, so we always pass -C
#                   explicitly. Suite 0 is refused below (it disables auth on
#                   the wire — CVE-2013-4783). Set 17 (HMAC-SHA256) if the BMC
#                   supports it.
#   IPMI_PRIVLEVEL  requested privilege level (-L: CALLBACK|USER|OPERATOR|
#                   ADMINISTRATOR). Default OPERATOR — ipmitool's own default is
#                   ADMINISTRATOR, more than monitoring needs; OPERATOR covers
#                   every read plus chassis power control. Drop to USER for a
#                   read-only account that lacks OPERATOR.
set -u

host=$1
shift

if [ -z "${IPMI_USER:-}" ]; then
	echo "dell-ipmi: set IPMI_USER and IPMI_PASSWORD in the runner environment (and allowlist them in inherit_env)" >&2
	exit 1
fi

if [ "${IPMI_CIPHER:-3}" = "0" ]; then
	echo "dell-ipmi: refusing RMCP+ cipher suite 0 — it disables authentication on the wire (CVE-2013-4783). Use 3 (default) or 17." >&2
	exit 1
fi

# ipmitool historically calls exit(0) even when the RMCP+ session fails: a bad
# credential, an unreachable BMC, or "IPMI Over LAN" disabled all surface only
# on stderr with an EMPTY stdout (the exit(rc) fix landed late and distro
# coverage varies). Capture stdout so an empty result becomes a real non-zero
# exit — this pack must fail loudly, never report a misleading empty success.
# stderr flows through to the action's stderr stream unchanged.
out=$(ipmitool -I lanplus -H "$host" -U "$IPMI_USER" -E \
	-C "${IPMI_CIPHER:-3}" -L "${IPMI_PRIVLEVEL:-OPERATOR}" "$@")
rc=$?
[ -n "$out" ] && printf '%s\n' "$out"
if [ "$rc" -ne 0 ]; then
	exit "$rc"
fi
if [ -z "$out" ]; then
	echo "dell-ipmi: ipmitool returned no output — the RMCP+ session failed (auth, unreachable BMC, or IPMI Over LAN disabled) or the command produced nothing" >&2
	exit 1
fi

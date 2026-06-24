#!/bin/sh
# idracreq.sh — packaged with the "dell-idrac" emisar pack. emisar loads it from
# disk when the pack is trusted, journals its SHA-256 with every run, and runs
# it via the interpreter named in each action. It is never fetched or assembled
# at request time.
#
# One Redfish call to a Dell iDRAC over HTTPS. Arguments:
#
#   $1   target iDRAC hostname or IP (the action's {{ args.host }}, bounded by
#        the action's validation.pattern).
#   $2   HTTP method: GET for reads, POST or DELETE for the few mutators.
#   $3   resource path under /redfish/v1, e.g. /Systems/System.Embedded.1. May
#        carry a query string ($expand, $filter); it is authored in the action
#        (or a bounded path arg), never free-form shell.
#   $4   optional JSON request body for POST — built in the action from bounded
#        enum args (e.g. {"ResetType":"GracefulRestart"}), never free-form.
#        Omit or pass "" for GET and DELETE.
#
# Auth is HTTP Basic from IDRAC_USER / IDRAC_PASSWORD, assembled into an
# Authorization header piped to curl over stdin (-H @-), so the credential never
# lands in argv, a `ps` listing, or the audit log. Basic auth is deliberate:
# unlike an X-Auth-Token session it consumes NO iDRAC session slot (iDRAC9
# allows only 8 concurrent), which is the right fit for stateless monitoring
# polls. iDRAC ships a self-signed cert, so TLS verification is skipped by
# default; set IDRAC_INSECURE=false once a CA-signed cert is installed.
set -u

host=$1
method=$2
path=$3
body=${4:-}

if [ -z "${IDRAC_USER:-}" ] || [ -z "${IDRAC_PASSWORD:-}" ]; then
	echo "dell-idrac: set IDRAC_USER and IDRAC_PASSWORD in the runner environment (and allowlist them in inherit_env)" >&2
	exit 1
fi

auth=$(printf '%s:%s' "$IDRAC_USER" "$IDRAC_PASSWORD" | base64 | tr -d '\n')

# Assemble curl's argument list. -H @- reads the auth header from the stdin
# piped in below, so the credential stays out of argv.
set -- -sS -X "$method" -H @- "https://$host/redfish/v1$path"
[ "${IDRAC_INSECURE:-true}" != "false" ] && set -- -k "$@"
if [ -n "$body" ]; then
	set -- "$@" -H "Content-Type: application/json" --data "$body"
fi

body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT INT TERM

# curl writes the response body to $body_file (-o) and prints the HTTP status
# code (-w) to stdout, which we capture. A 4xx/5xx from iDRAC (auth failure, bad
# path, session exhaustion) does NOT make curl exit non-zero by itself, so we
# inspect the code and fail loudly — while still surfacing the Redfish error
# body so the operator sees the iDRAC message.
code=$(printf 'Authorization: Basic %s\nAccept: application/json\n' "$auth" |
	curl "$@" -o "$body_file" -w '%{http_code}')
rc=$?
[ -s "$body_file" ] && cat "$body_file"

if [ "$rc" -ne 0 ]; then
	echo "dell-idrac: curl failed (exit $rc) reaching iDRAC at $host" >&2
	exit "$rc"
fi
case "$code" in
2*) ;;
*)
	echo "dell-idrac: iDRAC returned HTTP $code for $method $path" >&2
	exit 1
	;;
esac

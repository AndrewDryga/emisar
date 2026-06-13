#!/bin/sh
# pfreq.sh — packaged with the "pfsense" emisar pack. emisar loads it from
# disk when the pack is trusted, journals its SHA-256 with every run, and
# runs it via the interpreter named in each action. It is never fetched or
# assembled at request time.
#
# One request against the pfSense REST API — the community pfSense-pkg-RESTAPI
# package, base path /api/v2. Arguments:
#
#   $1     HTTP method (GET, POST, PATCH, DELETE).
#   $2     path under $PFSENSE_URL, e.g. /api/v2/status/system.
#   $3...  extra curl flags from the action — e.g. --data-raw '<json body>'.
#          Body values are rendered into argv by the cloud-validated template
#          engine and never enter a shell string.
#
# $PFSENSE_URL is the firewall's GUI/API base (scheme + host [+ port]); it
# defaults to a local pfSense. The API key is read from $PFSENSE_API_KEY and
# streamed to curl over stdin (-H @-), so it never lands in argv, a `ps`
# listing, or the audit log.
#
# TLS is verified by default. pfSense ships a self-signed GUI certificate, so
# set PFSENSE_INSECURE=true to skip verification, or point curl at a CA with
# the standard CURL_CA_BUNDLE env var to verify properly.
PFSENSE_URL=${PFSENSE_URL:-https://192.168.1.1}
method=$1
path=$2
shift 2

[ "${PFSENSE_INSECURE:-}" = "true" ] && set -- -k "$@"

if [ -n "${PFSENSE_API_KEY:-}" ]; then
	printf 'X-API-Key: %s\n' "$PFSENSE_API_KEY" |
		curl -sS -H @- -X "$method" -H "Content-Type: application/json" "$@" "$PFSENSE_URL$path"
else
	curl -sS -X "$method" -H "Content-Type: application/json" "$@" "$PFSENSE_URL$path"
fi

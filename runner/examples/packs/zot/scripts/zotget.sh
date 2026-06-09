#!/bin/sh
# zotget.sh — packaged with the "zot" emisar pack. emisar loads it from disk
# when the pack is trusted, journals its SHA-256 with every run, and runs it
# via the interpreter named in each action. It is never fetched or assembled
# at request time.
#
# One request against a zot OCI registry. $1 is the HTTP method (GET or POST
# for the search GraphQL extension), $2 the path under $ZOT_URL, $3... extra
# curl flags (e.g. -H 'Accept: ...' or --data for the search query; rendered
# into argv by the cloud-validated template engine, never a shell string).
# Optional basic-auth credentials "user:password" are read from $ZOT_BASICAUTH,
# base64-encoded, and streamed to curl as an Authorization header over stdin
# (-H @-) so they never land in argv, a `ps` listing, or the audit log. Many
# zot deployments allow anonymous read, in which case leave ZOT_BASICAUTH unset.
ZOT_URL=${ZOT_URL:-http://127.0.0.1:5000}
method=${1:-GET}
path=$2
shift 2
if [ -n "${ZOT_BASICAUTH:-}" ]; then
	printf 'Authorization: Basic %s\n' "$(printf '%s' "$ZOT_BASICAUTH" | base64 | tr -d '\n')" |
		curl -sS -X "$method" -H @- "$@" "$ZOT_URL$path"
else
	curl -sS -X "$method" "$@" "$ZOT_URL$path"
fi

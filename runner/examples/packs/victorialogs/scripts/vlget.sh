#!/bin/sh
# vlget.sh — packaged with the "victorialogs" emisar pack. emisar loads it
# from disk when the pack is trusted, journals its SHA-256 with every run,
# and runs it via the interpreter named in each action. It is never fetched
# or assembled at request time.
#
# Read-only GET against the VictoriaLogs LogsQL HTTP API.
#
#   $1     path appended to $VL_URL, e.g. /select/logsql/query.
#   $2...  extra curl flags — normally --data-urlencode "name=value" pairs.
#          Values are rendered into argv by the cloud-validated template
#          engine and URL-encoded by curl; they never enter a shell string.
#
# Optional request headers, streamed to curl over stdin (-H @-) so a token
# never lands in argv, a `ps` listing, or the audit log:
#
#   VL_BEARER_TOKEN  ->  Authorization: Bearer <token>   (vmauth front)
#   VL_ACCOUNT_ID    ->  AccountID: <id>                 (tenant; default 0)
#   VL_PROJECT_ID    ->  ProjectID: <id>                 (tenant; default 0)
: "${VL_URL:?set VL_URL to the VictoriaLogs base URL (scheme + host + port)}"

path=$1
shift

if [ -n "${VL_BEARER_TOKEN:-}${VL_ACCOUNT_ID:-}${VL_PROJECT_ID:-}" ]; then
	{
		[ -n "${VL_BEARER_TOKEN:-}" ] && printf 'Authorization: Bearer %s\n' "$VL_BEARER_TOKEN"
		[ -n "${VL_ACCOUNT_ID:-}" ] && printf 'AccountID: %s\n' "$VL_ACCOUNT_ID"
		[ -n "${VL_PROJECT_ID:-}" ] && printf 'ProjectID: %s\n' "$VL_PROJECT_ID"
	} | curl -sS -G -H @- "$@" "$VL_URL$path"
else
	curl -sS -G "$@" "$VL_URL$path"
fi

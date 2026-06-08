#!/bin/sh
# vmget.sh — packaged with the "victoriametrics" emisar pack. emisar loads
# it from disk when the pack is trusted, journals its SHA-256 with every
# run, and executes it via the interpreter named in each action. It is
# never fetched or assembled at request time.
#
# Read-only GET against the VictoriaMetrics / Prometheus-compatible query
# API. Arguments:
#
#   $1     path appended to $VM_URL, e.g. /api/v1/query. $VM_URL already
#          carries any /prometheus or /select/<accountID>/prometheus
#          prefix, so this one helper serves single-node, cluster, and
#          vmauth-fronted endpoints unchanged.
#   $2...  extra curl flags — normally --data-urlencode "name=value" pairs.
#          Values are rendered into argv by the cloud-validated template
#          engine and URL-encoded by curl; they never enter a shell string.
#
# When $VM_BEARER_TOKEN is set it is streamed to curl over stdin (-H @-),
# so the token never appears in argv, a `ps` listing, or the audit log.
: "${VM_URL:?set VM_URL to the VictoriaMetrics query base URL (scheme + host + port + any /prometheus prefix)}"

path=$1
shift

if [ -n "${VM_BEARER_TOKEN:-}" ]; then
	printf 'Authorization: Bearer %s\n' "$VM_BEARER_TOKEN" | curl -sS -G -H @- "$@" "$VM_URL$path"
else
	curl -sS -G "$@" "$VM_URL$path"
fi

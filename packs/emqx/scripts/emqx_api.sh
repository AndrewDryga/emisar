#!/bin/sh
# One request path for every EMQX action.
#
# The API key and secret ride a curl config document on stdin, never argv, so
# neither reaches /proc/<pid>/cmdline. EMQX_URL is operator-set, so the
# transfer is pinned to http/https and globbing is off.
set -eu

mode=$1

# Name the missing variable before any request: an unset one usually means it
# was not allowlisted in the runner's execution.inherit_env.
: "${EMQX_API_KEY:?is not set; allowlist it in the runner execution.inherit_env}"
: "${EMQX_API_SECRET:?is not set; allowlist it in the runner execution.inherit_env}"

api_base=${EMQX_URL:-http://127.0.0.1:18083}
api_base=${api_base%/}

case "$api_base" in
  http://* | https://*) ;;
  *)
    printf '%s\n' "EMQX_URL must be an http:// or https:// URL" >&2
    exit 2
    ;;
esac

request() {
  # --fail-with-body: a rejected pair comes back as
  # {"code":"BAD_API_KEY_OR_SECRET",...}, which is the whole diagnosis.
  printf 'user = "%s:%s"\n' "$EMQX_API_KEY" "$EMQX_API_SECRET" |
    curl -q --config - --fail-with-body --silent --show-error --globoff \
      --proto '=http,https' --connect-timeout 10 --max-time 20 \
      --max-filesize 4194304 "$@"
}

case "$mode" in
  nodes) request "$api_base/api/v5/nodes" ;;
  listeners) request "$api_base/api/v5/listeners" ;;
  stats) request "$api_base/api/v5/stats?aggregate=true" ;;
  # The Prometheus views answer JSON when asked, summed across the cluster.
  auth-metrics)
    request -H 'Accept: application/json' \
      "$api_base/api/v5/prometheus/auth?mode=all_nodes_aggregated"
    ;;
  rule-metrics)
    request -H 'Accept: application/json' \
      "$api_base/api/v5/prometheus/data_integration?mode=all_nodes_aggregated"
    ;;
  *)
    printf '%s\n' "unsupported EMQX operation: $mode" >&2
    exit 2
    ;;
esac

#!/bin/bash
# Fixed Elasticsearch API operations for the elasticsearch pack. The caller
# selects one packaged subcommand; it never supplies shell code, a URL host, a
# path, or a query string.
#
# Every action in this pack used to inline the same Basic-auth prelude, so the
# credential assembly and the curl flags were repeated 21 times and a fix to
# either was 21 edits with 21 chances to miss one.
#
# ELASTIC_URL is operator-set on the runner host, so the transfer is pinned to
# http/https and globbing is off. The credential is base64-encoded into an
# Authorization header delivered on stdin, never argv, so it stays out of
# /proc/<pid>/cmdline.
set -euo pipefail

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

api_base="${ELASTIC_URL:-http://127.0.0.1:9200}"
api_base="${api_base%/}"
case "$api_base" in
  http://* | https://*) ;;
  *) fail "ELASTIC_URL must be an http:// or https:// URL" ;;
esac
readonly api="$api_base"

# Anonymous clusters are a supported deployment, so an absent user is not an
# error — it simply sends no Authorization header.
auth_header() {
  if [[ -n "${ELASTIC_USER:-}" ]]; then
    printf 'Authorization: Basic '
    printf '%s:%s' "$ELASTIC_USER" "${ELASTIC_PASSWORD:-}" | base64 | tr -d '\n'
    printf '\n'
  fi
}

# $1 method, $2 path (already assembled by a subcommand from its own arguments).
request() {
  local method="$1" path="$2"
  auth_header | curl -q -fsS --globoff --proto '=http,https' \
    --connect-timeout 10 --max-time 3600 --max-filesize 8388608 \
    -H @- -X "$method" "$api$path"
}

# An index, repository, or snapshot name reaches this script as a positional
# argument and is only ever concatenated into a path — never into program text.
require_arg() {
  [[ -n "${2:-}" ]] || fail "$1 is required"
}

command="${1:-}"
shift || true

case "$command" in
  cluster-health) request GET "/_cluster/health?pretty" ;;
  cluster-settings) request GET "/_cluster/settings?include_defaults=false&pretty" ;;
  cluster-allocation-explain) request GET "/_cluster/allocation/explain?pretty" ;;
  pending-tasks) request GET "/_cluster/pending_tasks" ;;

  cat-aliases) request GET "/_cat/aliases?v" ;;
  cat-indices) request GET "/_cat/indices?v&s=store.size:desc" ;;
  cat-nodes) request GET "/_cat/nodes?v" ;;
  cat-recovery) request GET "/_cat/recovery?active_only=true&v" ;;
  cat-segments) request GET "/_cat/segments?v" ;;
  cat-shards) request GET "/_cat/shards?v&s=store:desc" ;;
  cat-thread-pool) request GET "/_cat/thread_pool?v" ;;

  index-count)
    require_arg index "${1:-}"
    request GET "/$1/_count?pretty"
    ;;
  index-mapping)
    require_arg index "${1:-}"
    request GET "/$1/_mapping?pretty"
    ;;
  index-settings)
    require_arg index "${1:-}"
    request GET "/$1/_settings?pretty"
    ;;
  index-stats)
    require_arg index "${1:-}"
    request GET "/$1/_stats?pretty"
    ;;

  cache-clear)
    require_arg index "${1:-}"
    request POST "/$1/_cache/clear?pretty"
    ;;
  close-index)
    require_arg index "${1:-}"
    request POST "/$1/_close?pretty"
    ;;
  flush)
    require_arg index "${1:-}"
    request POST "/$1/_flush?pretty"
    ;;
  force-merge)
    require_arg index "${1:-}"
    require_arg max_segments "${2:-}"
    # The action bounds max_segments to 1..100, and the loader only lets a
    # two-sided bounded number render into program text; it is re-checked here
    # because this script is also the thing an operator can run by hand.
    case "$2" in
      '' | *[!0-9]*) fail "max_segments must be a positive integer" ;;
    esac
    [[ "$2" -ge 1 && "$2" -le 100 ]] || fail "max_segments must be between 1 and 100"
    request POST "/$1/_forcemerge?max_num_segments=$2&pretty"
    ;;

  snapshot-list)
    require_arg repository "${1:-}"
    request GET "/_snapshot/$1/_all?pretty"
    ;;
  snapshot-status)
    require_arg repository "${1:-}"
    require_arg snapshot "${2:-}"
    request GET "/_snapshot/$1/$2/_status?pretty"
    ;;

  *) fail "unknown subcommand: ${command:-<none>}" ;;
esac

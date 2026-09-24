#!/bin/sh
# One request path for every EMQX action.
#
# The API key and secret ride a curl config document on stdin, never argv, so
# neither reaches /proc/<pid>/cmdline. EMQX_URL is operator-set, so the
# transfer is pinned to http/https and globbing is off. Identifiers go into
# their path segment percent-encoded byte by byte, and filters into query
# parameters through --data-urlencode, so no argument can change the request's
# path or add a parameter.
set -eu

mode=$1
shift

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

api=$api_base/api/v5

request() {
  # --fail-with-body: a rejected call comes back as {"code":...,"message":...},
  # which is the whole diagnosis (a bad key is BAD_API_KEY_OR_SECRET).
  printf 'user = "%s:%s"\n' "$EMQX_API_KEY" "$EMQX_API_SECRET" |
    curl -q --config - --fail-with-body --silent --show-error --globoff \
      --proto '=http,https' --connect-timeout 10 --max-time 20 \
      --max-filesize 4194304 "$@"
}

# Every byte of one path segment as %XX; EMQX decodes each segment.
segment() {
  printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n' | sed 's/../%&/g'
}

# GET api/$1 with each "name=value" after it as an encoded query parameter; a
# pair with an empty value is left out, so an unset filter matches everything.
get_query() {
  path=$1
  shift
  count=$#
  while [ "$count" -gt 0 ]; do
    pair=$1
    shift
    case "$pair" in
      *=) ;;
      *) set -- "$@" --data-urlencode "$pair" ;;
    esac
    count=$((count - 1))
  done
  request --get "$@" "$api/$path"
}

json_request() {
  request -H 'Content-Type: application/json' "$@"
}

# Values embedded in a JSON body are already validated to printable text; a
# quote or backslash could still end the string early, so refuse them here.
json_text() {
  case "$1" in
    *'"'* | *'\'*)
      printf '%s\n' "value must not contain a quote or backslash" >&2
      exit 2
      ;;
  esac
}

case "$mode" in
  nodes) request "$api/nodes" ;;
  listeners) request "$api/listeners" ;;
  stats) request "$api/stats?aggregate=true" ;;
  metrics) request "$api/metrics?aggregate=true" ;;
  rates) request "$api/monitor_current" ;;
  alarms)
    case "$1" in
      active) get_query alarms activated=true limit=100 ;;
      history) get_query alarms activated=false limit=100 ;;
      *)
        printf '%s\n' "alarms state must be active or history" >&2
        exit 2
        ;;
    esac
    ;;
  # The Prometheus views, summed across the cluster, in the text format: EMQX 6
  # no longer serves them as JSON.
  auth-metrics) request "$api/prometheus/auth?mode=all_nodes_aggregated" ;;
  rule-metrics) request "$api/prometheus/data_integration?mode=all_nodes_aggregated" ;;
  clients)
    # "any" leaves the connection-state filter out; EMQX knows only the two states.
    state=$5
    [ "$state" != any ] || state=
    get_query clients "limit=$1" "like_clientid=$2" "like_username=$3" \
      "ip_address=$4" "conn_state=$state" \
      "fields=clientid,username,ip_address,connected,connected_at,node,proto_ver,keepalive,clean_start,subscriptions_cnt,inflight_cnt,mqueue_len,mqueue_dropped,recv_msg,send_msg"
    ;;
  client) request "$api/clients/$(segment "$1")" ;;
  subscriptions) get_query subscriptions "limit=$1" "clientid=$2" "match_topic=$3" ;;
  topics) get_query topics "limit=$1" "topic=$2" ;;
  retained) get_query mqtt/retainer/messages "limit=$1" "topic=$2" ;;
  retained-message) request "$api/mqtt/retainer/message/$(segment "$1")" ;;
  rules) get_query rules "limit=$1" ;;
  banned) get_query banned "limit=$1" ;;
  authz-settings) request "$api/authorization/settings" ;;
  kick-client)
    request -X DELETE "$api/clients/$(segment "$1")"
    printf '%s\n' '{"kicked":true}'
    ;;
  delete-retained)
    request -X DELETE "$api/mqtt/retainer/message/$(segment "$1")"
    printf '%s\n' '{"deleted":true}'
    ;;
  set-rule-enabled)
    case "$2" in
      true | false) ;;
      *)
        printf '%s\n' "enable must be true or false" >&2
        exit 2
        ;;
    esac
    json_request -X PUT --data-binary "{\"enable\":$2}" "$api/rules/$(segment "$1")"
    ;;
  start-connector)
    request -X POST "$api/connectors/$(segment "$1")/start"
    printf '%s\n' '{"started":true}'
    ;;
  set-data-action-enabled)
    case "$2" in
      true | false) ;;
      *)
        printf '%s\n' "enable must be true or false" >&2
        exit 2
        ;;
    esac
    request -X PUT "$api/actions/$(segment "$1")/enable/$2"
    printf '{"enable":%s}\n' "$2"
    ;;
  restart-listener)
    request -X POST "$api/listeners/$(segment "$1")/restart"
    printf '%s\n' '{"restarted":true}'
    ;;
  ban)
    case "$1" in
      clientid | username | peerhost) ;;
      *)
        printf '%s\n' "ban kind must be clientid, username, or peerhost" >&2
        exit 2
        ;;
    esac
    json_text "$2"
    json_text "$3"
    case "$4" in
      0) expiry= ;;
      *[!0-9]* | '')
        printf '%s\n' "minutes must be a whole number" >&2
        exit 2
        ;;
      # EMQX takes an absolute RFC 3339 expiry; GNU and busybox date both
      # format an epoch given as @seconds.
      *) expiry=$(date -u -d "@$(($(date -u +%s) + $4 * 60))" '+%Y-%m-%dT%H:%M:%SZ') ;;
    esac
    body="{\"as\":\"$1\",\"who\":\"$2\",\"reason\":\"$3\""
    [ -z "$expiry" ] || body="$body,\"until\":\"$expiry\""
    json_request -X POST --data-binary "$body}" "$api/banned"
    ;;
  unban)
    request -X DELETE "$api/banned/$(segment "$1")/$(segment "$2")"
    printf '%s\n' '{"unbanned":true}'
    ;;
  *)
    printf '%s\n' "unsupported EMQX operation: $mode" >&2
    exit 2
    ;;
esac

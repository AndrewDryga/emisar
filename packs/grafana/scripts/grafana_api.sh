#!/bin/sh
# One request path for every Grafana action.
#
# The credential rides a curl config document on stdin, never argv: every
# action here used to pass -u "$GRAFANA_USER:$GRAFANA_PASSWORD" or an
# Authorization header on the command line, which puts it in /proc/<pid>/cmdline
# for the life of the call. Every other credentialed pack in this catalog
# already streams it, and now so does this one.
#
# GRAFANA_URL is operator-set, so the transfer is pinned to http/https and
# globbing is off — a {a,b} in a URL segment would otherwise expand into one
# transfer per alternative.
set -eu

mode=$1

api_base=${GRAFANA_URL:-http://127.0.0.1:3000}
api_base=${api_base%/}

case "$api_base" in
  http://* | https://*) ;;
  *)
    printf '%s\n' "GRAFANA_URL must be an http:// or https:// URL" >&2
    exit 2
    ;;
esac

# Basic auth when a user is set, otherwise the service-account token. Both are
# written as curl config directives so neither reaches the process table.
auth_config() {
  if [ -n "${GRAFANA_USER:-}" ]; then
    printf 'user = "%s:%s"\n' "$GRAFANA_USER" "${GRAFANA_PASSWORD:-}"
  else
    printf 'header = "Authorization: Bearer %s"\n' "${GRAFANA_TOKEN:-}"
  fi
}

request() {
  auth_config | curl -q --config - --fail --silent --show-error --globoff \
    --proto '=http,https' --connect-timeout 10 --max-time 60 \
    --max-filesize 4194304 "$@"
}

case "$mode" in
  alerting-rules) request "$api_base/api/prometheus/grafana/api/v1/rules" ;;
  alerting-state) request "$api_base/api/alertmanager/grafana/api/v2/alerts" ;;
  datasources) request "$api_base/api/datasources" ;;
  health) request "$api_base/api/health" ;;
  orgs) request "$api_base/api/orgs" ;;
  settings) request "$api_base/api/admin/settings" ;;
  users) request "$api_base/api/org/users" ;;
  version) request "$api_base/api/frontend/settings" ;;

  # --get + --data-urlencode so the search term is encoded by curl rather than
  # pasted into the query string, which is what the inline form did.
  dashboards-search)
    request --get \
      --data-urlencode "type=dash-db" \
      --data-urlencode "query=$2" \
      "$api_base/api/search"
    ;;

  datasource-health) request "$api_base/api/datasources/uid/$2/health" ;;

  *)
    printf '%s\n' "unsupported Grafana operation: $mode" >&2
    exit 2
    ;;
esac

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

# GET /api/datasources returns each datasource as configured, and two of its
# fields are operator- and plugin-authored: jsonData, whose keys a community
# plugin invents, and url, which may carry basic-auth userinfo. Neither key
# space is enumerable, so no redaction rule can cover them — the projection
# picks the fields instead. strip_userinfo is bunnycdn's sanitize_origin
# verbatim (packs/bunnycdn/scripts/bunny_api.sh): the obvious spelling needs
# test()/capture(), which exist only in a jq linked against Oniguruma.
safe_datasources() {
  jq -ce '
    def strip_userinfo($scheme):
      ltrimstr($scheme) as $rest
      | if $rest == . then null
        else ($rest | split("@")) as $parts
          | if ($parts | length) < 2 or ($parts[0] | length) == 0 or
               ($parts[0] | contains("/"))
            then null
            else $scheme + ($parts[1:] | join("@"))
            end
        end;
    def sanitize_origin:
      if type == "string" then
        strip_userinfo("https://") // strip_userinfo("http://") // .
      else . end;
    [ .[]? | {
        id, uid, name, type, access, database, basicAuth, isDefault, readOnly,
        url: (.url | sanitize_origin),
        json_data_keys: ((.jsonData // {}) | keys)
      } ]
  '
}

case "$mode" in
  alerting-rules) request "$api_base/api/prometheus/grafana/api/v1/rules" ;;
  alerting-state) request "$api_base/api/alertmanager/grafana/api/v2/alerts" ;;
  # Captured, not piped live: a pipeline exits with jq's status, so a 401 from
  # curl would be projected into an empty array and read as "no datasources".
  datasources)
    datasources_response=$(request "$api_base/api/datasources")
    printf '%s' "$datasources_response" | safe_datasources
    ;;
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

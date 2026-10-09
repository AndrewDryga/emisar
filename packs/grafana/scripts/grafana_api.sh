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
  # --fail-with-body: Grafana answers a rejected request with {"message": ...},
  # which is the whole diagnosis for a wrong org, folder, or token scope.
  auth_config | curl -q --config - --fail-with-body --silent --show-error --globoff \
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

# These two status reads never forward the settings/query/config document.
# Slurp requires exactly one typed JSON value; omitted labels/totals are valid
# in native empty or recording-rule responses, but wrong types are not.
safe_alerting_rules() {
  jq -cse '
    def optional($key; check): if has($key) then .[$key] | check else true end;
    def strings: type == "object" and all(.[]; type == "string");
    def totals: type == "object" and all(.[]; type == "number" and . >= 0 and . == floor);
    def rule:
      type == "object" and (.uid | type == "string" and length > 0)
      and (.name | type == "string") and (.type | type == "string")
      and (.isPaused | type == "boolean") and (.health | type == "string")
      and (.lastEvaluation | type == "string") and optional("state"; type == "string")
      and optional("labels"; strings) and optional("totals"; totals);
    def group:
      type == "object" and (.name | type == "string") and (.file | type == "string")
      and (.folderUid | type == "string") and (.interval | type == "number" and . >= 0)
      and (.lastEvaluation | type == "string") and optional("totals"; totals)
      and (.rules | type == "array" and all(.[]; rule));
    if length != 1 or (.[0] | type != "object") then error("invalid document") else .[0] end
    | if .status != "success" or (.data | type != "object")
         or (.data.groups | type != "array" or (all(.[]; group) | not))
         or (.data | optional("totals"; totals) | not)
         or (.data | optional("groupNextToken"; type == "string" and length == 0) | not)
      then error("invalid or incomplete rule document") else . end
    | {status, data: {
        totals: (.data.totals // {}),
        groups: [.data.groups[] | {name, file, folderUid, interval, lastEvaluation,
          totals: (.totals // {}), rules: [.rules[] |
            {uid, name, type, isPaused, health, lastEvaluation,
             labels: (.labels // {}), totals: (.totals // {})}
            + (if has("state") then {state} else {} end)]}]
      }}
  ' "$1"
}

safe_version() {
  jq -cse '
    if length != 1 or (.[0] | type != "object") then error("invalid document") else .[0] end
    | if (.buildInfo | type != "object") or (.licenseInfo | type != "object")
         or ([.buildInfo.version, .buildInfo.commit, .buildInfo.edition, .buildInfo.env,
              .licenseInfo.edition, .licenseInfo.stateInfo] | all(.[]; type == "string") | not)
         or (.licenseInfo.expiry | type != "number" or . != floor)
      then error("invalid build or license information") else . end
    | {buildInfo: (.buildInfo | {version, commit, edition, env}),
       licenseInfo: (.licenseInfo | {expiry, edition, stateInfo})}
  ' "$1"
}

projected_request() {
  projection=$1
  budget=$2
  shift 2
  umask 077
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-grafana-status.XXXXXX")
  trap 'rm -f -- "$tmp/response" "$tmp/status" "$tmp/diagnostic" "$tmp/projected"; rmdir -- "$tmp"' EXIT HUP INT TERM
  rc=0
  request --output "$tmp/response" --write-out '%{http_code}' "$@" \
    >"$tmp/status" 2>"$tmp/diagnostic" || rc=$?
  status=$(tr -d '\n' <"$tmp/status")
  if [ "$rc" -ne 0 ]; then
    printf 'Grafana %s request failed (client code %s, HTTP %s)\n' "$mode" "$rc" "$status" >&2
    # A genuine HTTP rejection is useful. A partial successful body may contain
    # credentials, so transport/size failures never replay it or curl diagnostics.
    case "$rc:$status" in
      22:4??|22:5??) head -c 8192 "$tmp/response" >&2 ;;
    esac
    exit "$rc"
  fi
  case "$status" in
    2??) ;;
    *) printf 'Grafana returned unexpected HTTP %s\n' "$status" >&2; exit 1 ;;
  esac
  if [ "$(wc -c <"$tmp/response")" -gt 4194304 ]; then
    printf '%s\n' 'Grafana response exceeds the 4 MiB transport budget' >&2
    exit 1
  fi
  if ! "$projection" "$tmp/response" >"$tmp/projected" 2>"$tmp/diagnostic"; then
    printf 'Grafana returned invalid or incomplete %s JSON\n' "$mode" >&2
    exit 1
  fi
  if [ "$(wc -c <"$tmp/projected")" -gt "$budget" ]; then
    printf 'Grafana %s output exceeds the %s-byte budget; no partial result returned\n' "$mode" "$budget" >&2
    exit 1
  fi
  cat "$tmp/projected"
}

case "$mode" in
  alerting-rules)
    projected_request safe_alerting_rules 262144 --get --data-urlencode 'limit_alerts=0' \
      "$api_base/api/prometheus/grafana/api/v1/rules"
    ;;
  alerting-state) request "$api_base/api/alertmanager/grafana/api/v2/alerts" ;;
  # Captured, not piped live: a pipeline exits with jq's status, so a 401 from
  # curl would be projected into an empty array and read as "no datasources".
  # Capturing means this branch owns the failure report too — --fail-with-body
  # put Grafana's {"message": ...} in the variable, and `set -e` on the
  # assignment would end the run before anything printed it, leaving the
  # operator with curl's `(22)` line and no wrong-org/folder/scope diagnosis.
  datasources)
    rc=0
    datasources_response=$(request "$api_base/api/datasources") || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ -n "$datasources_response" ]; then
        printf '%s\n' "$datasources_response" >&2
      fi
      exit "$rc"
    fi
    printf '%s' "$datasources_response" | safe_datasources
    ;;
  health) request "$api_base/api/health" ;;
  orgs) request "$api_base/api/orgs" ;;
  settings) request "$api_base/api/admin/settings" ;;
  users) request "$api_base/api/org/users" ;;
  version) projected_request safe_version 8192 "$api_base/api/frontend/settings" ;;

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

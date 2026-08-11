#!/bin/bash
# Fixed Cloudflare API v4 operations for the cloudflare pack. The caller
# selects one packaged subcommand; it never supplies shell code, a URL host,
# or a JSON body.
set -euo pipefail

readonly max_response_bytes=16777216
readonly api_base="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

require_token() {
  [[ -n "${CF_API_TOKEN:-}" ]] || fail "CF_API_TOKEN is required"
}

# The behavior fixture serves a mock inside its Compose network, so the base
# override is pinned to THAT destination rather than left open: an unrestricted
# override means anyone who can set CF_PACKTEST=1 can also point CF_API_BASE at
# a host of their choosing and walk off with CF_API_TOKEN. "cloudflare-api"
# does not resolve outside the test network.
readonly packtest_base="http://cloudflare-api:8080"

packtest() {
  [[ "${CF_PACKTEST:-}" == "1" ]]
}

validate_base() {
  if packtest; then
    [[ "$api_base" == "$packtest_base"/* ]] || fail "test API base must be under $packtest_base"
    return
  fi
  [[ "$api_base" == "https://api.cloudflare.com/client/v4" ]] || fail "CF_API_BASE is test-only"
}

# curl's protocol allowlist follows the same switch as the destination pin. In
# production the base is pinned to an exact https URL, so '=https' simply
# states what it already is; the fixture's mock speaks plain http.
curl_protocols() {
  if packtest; then
    printf '%s' '=https,http'
  else
    printf '%s' '=https'
  fi
}

request() {
  local method=$1 url=$2 response status=0
  shift 2

  response=$(printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN" |
    curl --globoff --proto "$(curl_protocols)" -fsS -X "$method" -H @- "$@" "$url") || status=$?
  ((status == 0)) || fail "Cloudflare API request failed"
  ((${#response} <= max_response_bytes)) || fail "Cloudflare API response exceeded 16 MiB"
  printf '%s' "$response"
}

# Every REST response carries the v4 envelope. A 2xx whose envelope says
# success:false is still a failure and must not read as a healthy run.
respond() {
  local response=$1
  printf '%s' "$response" | jq -e '.success == true' >/dev/null ||
    fail "Cloudflare API reported failure"
  printf '%s\n' "$response" | jq -ce .
}

rest() {
  local method=$1 path=$2
  shift 2
  respond "$(request "$method" "$api_base$path" "$@")"
}

rest_json() {
  local method=$1 path=$2 body=$3
  rest "$method" "$path" -H 'Content-Type: application/json' --data "$body"
}

hours_ago() {
  jq -nr --argjson hours "$1" 'now - ($hours * 3600) | todate'
}

list_zones() {
  local name=$1 status_filter=$2 page=$3 per_page=$4
  local -a query=(-G --data-urlencode "page=$page" --data-urlencode "per_page=$per_page")
  [[ -z "$name" ]] || query+=(--data-urlencode "name=$name")
  [[ -z "$status_filter" ]] || query+=(--data-urlencode "status=$status_filter")
  rest GET /zones "${query[@]}"
}

list_accounts() {
  rest GET /accounts -G --data-urlencode "page=$1" --data-urlencode "per_page=$2"
}

zone_details() {
  rest GET "/zones/$1"
}

zone_settings() {
  rest GET "/zones/$1/settings"
}

dns_records() {
  local zone_id=$1 record_type=$2 name=$3 content=$4 page=$5 per_page=$6
  local -a query=(-G --data-urlencode "page=$page" --data-urlencode "per_page=$per_page")
  [[ -z "$record_type" ]] || query+=(--data-urlencode "type=$record_type")
  [[ -z "$name" ]] || query+=(--data-urlencode "name=$name")
  [[ -z "$content" ]] || query+=(--data-urlencode "content=$content")
  rest GET "/zones/$zone_id/dns_records" "${query[@]}"
}

firewall_rules() {
  rest GET "/zones/$1/rulesets/phases/http_request_firewall_custom/entrypoint"
}

list_rulesets() {
  rest GET "/zones/$1/rulesets"
}

list_ip_access_rules() {
  local zone_id=$1 mode=$2 page=$3 per_page=$4
  local -a query=(-G --data-urlencode "page=$page" --data-urlencode "per_page=$per_page")
  [[ -z "$mode" ]] || query+=(--data-urlencode "mode=$mode")
  rest GET "/zones/$zone_id/firewall/access_rules/rules" "${query[@]}"
}

ssl_verification() {
  rest GET "/zones/$1/ssl/verification"
}

list_certificate_packs() {
  rest GET "/zones/$1/ssl/certificate_packs"
}

page_rules() {
  rest GET "/zones/$1/pagerules"
}

list_worker_routes() {
  rest GET "/zones/$1/workers/routes"
}

list_tunnels() {
  rest GET "/accounts/$1/cfd_tunnel" -G \
    --data-urlencode "is_deleted=false" \
    --data-urlencode "page=$2" \
    --data-urlencode "per_page=$3"
}

tunnel_connections() {
  rest GET "/accounts/$1/cfd_tunnel/$2/connections"
}

list_load_balancers() {
  rest GET "/zones/$1/load_balancers"
}

list_lb_pools() {
  rest GET "/accounts/$1/load_balancers/pools"
}

lb_pool_health() {
  rest GET "/accounts/$1/load_balancers/pools/$2/health"
}

audit_logs() {
  local account_id=$1 hours=$2 page=$3 per_page=$4
  rest GET "/accounts/$account_id/audit_logs" -G \
    --data-urlencode "since=$(hours_ago "$hours")" \
    --data-urlencode "page=$page" \
    --data-urlencode "per_page=$per_page"
}

readonly http_report_query='query($zone: String!, $since: Time!, $until: Time!) {
  viewer {
    zones(filter: {zoneTag: $zone}) {
      httpRequests1hGroups(
        limit: 72,
        filter: {datetime_geq: $since, datetime_lt: $until},
        orderBy: [datetime_ASC]
      ) {
        dimensions { datetime }
        sum { requests bytes cachedRequests cachedBytes threats pageViews }
        uniq { uniques }
      }
    }
  }
}'

zone_analytics() {
  local zone_id=$1 hours=$2 since_ts until_ts response
  since_ts=$(hours_ago "$hours")
  until_ts=$(jq -nr 'now | todate')
  response=$(request POST "$api_base/graphql" -H 'Content-Type: application/json' --data "$(
    jq -nc --arg query "$http_report_query" \
      --arg zone "$zone_id" --arg since "$since_ts" --arg until "$until_ts" \
      '{query: $query, variables: {zone: $zone, since: $since, until: $until}}'
  )")
  # GraphQL reports failure inside a 200 body, so transport success alone is
  # not enough.
  printf '%s' "$response" | jq -e '(.errors // []) | length == 0' >/dev/null ||
    fail "Cloudflare GraphQL query failed"
  printf '%s' "$response" | jq -ce --arg since "$since_ts" --arg until "$until_ts" '
    (.data.viewer.zones[0].httpRequests1hGroups // []) as $groups
    | {
        since: $since,
        until: $until,
        totals: {
          requests: ([$groups[].sum.requests] | add // 0),
          bytes: ([$groups[].sum.bytes] | add // 0),
          cached_requests: ([$groups[].sum.cachedRequests] | add // 0),
          cached_bytes: ([$groups[].sum.cachedBytes] | add // 0),
          threats: ([$groups[].sum.threats] | add // 0),
          page_views: ([$groups[].sum.pageViews] | add // 0),
          uniques: ([$groups[].uniq.uniques] | add // 0)
        },
        series: $groups
      }'
}

dns_analytics_report() {
  local zone_id=$1 hours=$2 limit=$3
  rest GET "/zones/$zone_id/dns_analytics/report" -G \
    --data-urlencode "metrics=queryCount" \
    --data-urlencode "dimensions=queryName,queryType,responseCode" \
    --data-urlencode "since=$(hours_ago "$hours")" \
    --data-urlencode "until=$(jq -nr 'now | todate')" \
    --data-urlencode "limit=$limit"
}

purge_body() {
  rest_json POST "/zones/$1/purge_cache" "$2"
}

purge_all_cache() {
  purge_body "$1" '{"purge_everything":true}'
}

purge_url() {
  local url=${CF_PURGE_URL:?CF_PURGE_URL is required}
  purge_body "$1" "$(jq -nc --arg url "$url" '{files: [$url]}')"
}

purge_hostname() {
  purge_body "$1" "$(jq -nc --arg value "$2" '{hosts: [$value]}')"
}

purge_prefix() {
  purge_body "$1" "$(jq -nc --arg value "$2" '{prefixes: [$value]}')"
}

purge_tag() {
  purge_body "$1" "$(jq -nc --arg value "$2" '{tags: [$value]}')"
}

patch_setting() {
  local zone_id=$1 setting=$2 value=$3
  rest_json PATCH "/zones/$zone_id/settings/$setting" "$(jq -nc --arg value "$value" '{value: $value}')"
}

set_zone_paused() {
  rest_json PATCH "/zones/$1" "$(jq -nc --argjson paused "$2" '{paused: $paused}')"
}

create_dns_record() {
  local zone_id=$1 record_type=$2 name=$3 content=$4 ttl=$5 proxied=$6 priority=$7 comment=$8
  rest_json POST "/zones/$zone_id/dns_records" "$(
    jq -nc \
      --arg type "$record_type" --arg name "$name" --arg content "$content" \
      --argjson ttl "$ttl" --arg proxied "$proxied" --argjson priority "$priority" \
      --arg comment "$comment" '
      {type: $type, name: $name, content: $content, ttl: $ttl}
      + (if $type == "A" or $type == "AAAA" or $type == "CNAME"
         then {proxied: ($proxied == "true")} else {} end)
      + (if $type == "MX" then {priority: $priority} else {} end)
      + (if $comment == "" then {} else {comment: $comment} end)'
  )"
}

update_dns_record() {
  local zone_id=$1 record_id=$2 record_type=$3 name=$4 content=$5 ttl=$6 proxied=$7 comment=$8
  local body
  body=$(jq -nc \
    --arg type "$record_type" --arg name "$name" --arg content "$content" \
    --argjson ttl "$ttl" --arg proxied "$proxied" --arg comment "$comment" '
    (if $type == "" then {} else {type: $type} end)
    + (if $name == "" then {} else {name: $name} end)
    + (if $content == "" then {} else {content: $content} end)
    + (if $ttl == 0 then {} else {ttl: $ttl} end)
    + (if $proxied == "" then {} else {proxied: ($proxied == "true")} end)
    + (if $comment == "" then {} else {comment: $comment} end)')
  [[ "$body" != "{}" ]] || fail "at least one record field must change"
  rest_json PATCH "/zones/$zone_id/dns_records/$record_id" "$body"
}

delete_dns_record() {
  rest DELETE "/zones/$1/dns_records/$2"
}

create_ip_access_rule() {
  local zone_id=$1 mode=$2 target=$3 value=$4 notes=$5
  rest_json POST "/zones/$zone_id/firewall/access_rules/rules" "$(
    jq -nc --arg mode "$mode" --arg target "$target" --arg value "$value" --arg notes "$notes" '
      {mode: $mode, configuration: {target: $target, value: $value}}
      + (if $notes == "" then {} else {notes: $notes} end)'
  )"
}

delete_ip_access_rule() {
  rest DELETE "/zones/$1/firewall/access_rules/rules/$2"
}

set_lb_pool_enabled() {
  rest_json PATCH "/accounts/$1/load_balancers/pools/$2" "$(jq -nc --argjson enabled "$3" '{enabled: $enabled}')"
}

require_token
validate_base

command=${1:-}
shift || true
case "$command" in
  list-zones) list_zones "$@" ;;
  list-accounts) list_accounts "$@" ;;
  zone-details) zone_details "$@" ;;
  zone-settings) zone_settings "$@" ;;
  dns-records) dns_records "$@" ;;
  firewall-rules) firewall_rules "$@" ;;
  list-rulesets) list_rulesets "$@" ;;
  list-ip-access-rules) list_ip_access_rules "$@" ;;
  ssl-verification) ssl_verification "$@" ;;
  list-certificate-packs) list_certificate_packs "$@" ;;
  page-rules) page_rules "$@" ;;
  list-worker-routes) list_worker_routes "$@" ;;
  list-tunnels) list_tunnels "$@" ;;
  tunnel-connections) tunnel_connections "$@" ;;
  list-load-balancers) list_load_balancers "$@" ;;
  list-lb-pools) list_lb_pools "$@" ;;
  lb-pool-health) lb_pool_health "$@" ;;
  audit-logs) audit_logs "$@" ;;
  zone-analytics) zone_analytics "$@" ;;
  dns-analytics-report) dns_analytics_report "$@" ;;
  purge-all-cache) purge_all_cache "$@" ;;
  purge-url) purge_url "$@" ;;
  purge-hostname) purge_hostname "$@" ;;
  purge-prefix) purge_prefix "$@" ;;
  purge-tag) purge_tag "$@" ;;
  dev-mode) patch_setting "$1" development_mode "$2" ;;
  set-security-level) patch_setting "$1" security_level "$2" ;;
  set-ssl-mode) patch_setting "$1" ssl "$2" ;;
  set-min-tls-version) patch_setting "$1" min_tls_version "$2" ;;
  set-always-use-https) patch_setting "$1" always_use_https "$2" ;;
  set-zone-paused) set_zone_paused "$@" ;;
  create-dns-record) create_dns_record "$@" ;;
  update-dns-record) update_dns_record "$@" ;;
  delete-dns-record) delete_dns_record "$@" ;;
  create-ip-access-rule) create_ip_access_rule "$@" ;;
  delete-ip-access-rule) delete_ip_access_rule "$@" ;;
  set-lb-pool-enabled) set_lb_pool_enabled "$@" ;;
  *) fail "unknown cloudflare operation" ;;
esac

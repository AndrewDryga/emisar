#!/bin/bash
# Fixed bunny.net API operations for the bunnycdn pack. The caller selects one
# packaged subcommand; it never supplies shell code, a URL host, or a JSON body.
set -euo pipefail

readonly max_response_bytes=16777216
readonly core_base="${BUNNY_CORE_API_BASE:-https://api.bunny.net}"
readonly logging_base="${BUNNY_LOGGING_API_BASE:-https://logging.bunnycdn.com/v2}"
readonly origin_errors_base="${BUNNY_ORIGIN_ERRORS_API_BASE:-https://cdn-origin-logging.bunny.net}"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

require_key() {
  [[ -n "${BUNNY_API_KEY:-}" ]] || fail "BUNNY_API_KEY is required"
}

# The behavior fixture serves a mock inside its Compose network, so the base
# overrides are pinned to THAT destination rather than left open: an unrestricted
# override means anyone who can set BUNNY_PACKTEST=1 can also point
# BUNNY_CORE_API_BASE at a host of their choosing and walk off with
# BUNNY_API_KEY. "bunny-api" does not resolve outside the test network.
readonly packtest_base="http://bunny-api:8080"

packtest() {
  [[ "${BUNNY_PACKTEST:-}" == "1" ]]
}

validate_bases() {
  if packtest; then
    local base
    for base in "$core_base" "$logging_base" "$origin_errors_base"; do
      [[ "$base" == "$packtest_base"/* ]] || fail "test API base must be under $packtest_base"
    done
    return
  fi
  [[ "$core_base" == "https://api.bunny.net" ]] || fail "BUNNY_CORE_API_BASE is test-only"
  [[ "$logging_base" == "https://logging.bunnycdn.com/v2" ]] || fail "BUNNY_LOGGING_API_BASE is test-only"
  [[ "$origin_errors_base" == "https://cdn-origin-logging.bunny.net" ]] || fail "BUNNY_ORIGIN_ERRORS_API_BASE is test-only"
}

# curl's protocol allowlist follows the same switch as the destination pin. In
# production every base is pinned to an exact https URL, so '=https' simply
# states what they already are; the fixture's mock speaks plain http.
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

  response=$(printf 'AccessKey: %s\n' "$BUNNY_API_KEY" |
    curl --globoff --proto "$(curl_protocols)" -fsS -X "$method" -H @- "$@" "$url") || status=$?
  ((status == 0)) || fail "bunny.net API request failed"
  ((${#response} <= max_response_bytes)) || fail "bunny.net API response exceeded 16 MiB"
  printf '%s' "$response"
}

request_json() {
  local method=$1 url=$2 body=$3
  request "$method" "$url" -H 'Content-Type: application/json' --data "$body"
}

safe_pull_zone() {
  # An origin URL can carry credentials in its userinfo, so they are cut out
  # before the zone leaves the runner. The obvious spelling needs test() and
  # capture(), which exist only in a jq linked against Oniguruma — on the
  # supported --with-oniguruma=no build every pull-zone read would fail after
  # the API call. strip_userinfo says the same thing on core jq: after the
  # scheme, a non-empty userinfo segment must end at the first @, and that @
  # must come before any / (an @ inside a path is not userinfo). split is the
  # cut rather than index, whose offsets are bytes while a slice counts
  # codepoints.
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
    walk(
      if type == "object" then
        del(
          .ZoneSecurityKey,
          .AWSSigningKey,
          .AWSSigningSecret,
          .LogForwardingToken,
          .Certificate,
          .CertificateKey
        )
        | if has("OriginUrl") then .OriginUrl |= sanitize_origin else . end
      else . end
    )
  '
}

safe_logs() {
  jq -ce '
    def without_query:
      if type == "string" then split("?")[0] else . end;
    .data |= map(
      del(.authorizationHeader, .AuthorizationHeader)
      | if has("path") then .path |= without_query else . end
      | if has("url") then .url |= without_query else . end
      | if .referer? != null then .referer |= without_query else . end
    )
  '
}

get_pull_zone_raw() {
  request GET "$core_base/pullzone/$1"
}

get_pull_zone() {
  get_pull_zone_raw "$1" | safe_pull_zone
}

update_pull_zone() {
  local pull_zone_id=$1 body=$2
  request_json POST "$core_base/pullzone/$pull_zone_id" "$body" >/dev/null
  get_pull_zone "$pull_zone_id"
}

mutate_pull_zone_resource() {
  local method=$1 pull_zone_id=$2 resource=$3 body=$4
  request_json "$method" "$core_base/pullzone/$pull_zone_id/$resource" "$body" >/dev/null
  get_pull_zone "$pull_zone_id"
}

list_pull_zones() {
  local search=$1 page=$2 per_page=$3
  request GET "$core_base/pullzone" -G \
    --data-urlencode "page=$page" \
    --data-urlencode "perPage=$per_page" \
    --data-urlencode "search=$search" |
    safe_pull_zone
}

list_regions() {
  request GET "$core_base/region" | jq -ce .
}

statistics() {
  local date_from=$1 date_to=$2 pull_zone_id=$3 hourly=$4
  local -a query=(
    -G
    --data-urlencode "hourly=$hourly"
    --data-urlencode "exactRange=$hourly"
    --data-urlencode "loadErrors=true"
    --data-urlencode "loadOriginResponseTimes=true"
    --data-urlencode "loadOriginTraffic=true"
    --data-urlencode "loadRequestsServed=true"
    --data-urlencode "loadBandwidthUsed=true"
    --data-urlencode "loadOriginShieldBandwidth=true"
    --data-urlencode "loadGeographicTrafficDistribution=true"
  )
  [[ -z "$date_from" ]] || query+=(--data-urlencode "dateFrom=$date_from")
  [[ -z "$date_to" ]] || query+=(--data-urlencode "dateTo=$date_to")
  [[ "$pull_zone_id" == "0" ]] || query+=(--data-urlencode "pullZone=$pull_zone_id")
  request GET "$core_base/statistics" "${query[@]}" | jq -ce .
}

product_statistics() {
  local pull_zone_id=$1 product=$2 date_from=$3 date_to=$4 hourly=$5
  local -a query=(-G --data-urlencode "hourly=$hourly")
  [[ -z "$date_from" ]] || query+=(--data-urlencode "dateFrom=$date_from")
  [[ -z "$date_to" ]] || query+=(--data-urlencode "dateTo=$date_to")
  request GET "$core_base/pullzone/$pull_zone_id/$product/statistics" "${query[@]}" | jq -ce .
}

origin_shield_statistics() {
  local pull_zone_id=$1 date_from=$2 date_to=$3 hourly=$4
  local -a query=(-G --data-urlencode "hourly=$hourly")
  [[ -z "$date_from" ]] || query+=(--data-urlencode "dateFrom=$date_from")
  [[ -z "$date_to" ]] || query+=(--data-urlencode "dateTo=$date_to")
  request GET "$core_base/pullzone/$pull_zone_id/originshield/queuestatistics" "${query[@]}" | jq -ce .
}

logs_response() {
  local pull_zone_id=$1 from=$2 to=$3 status_filter=$4 cache_status=$5 url_contains=$6 limit=$7 offset=$8 order=$9 include_shield=${10}
  local -a query=(
    -G
    --data-urlencode "limit=$limit"
    --data-urlencode "offset=$offset"
    --data-urlencode "order=$order"
    --data-urlencode "includeOriginShield=$include_shield"
  )
  [[ -z "$from" ]] || query+=(--data-urlencode "from=$from")
  [[ -z "$to" ]] || query+=(--data-urlencode "to=$to")
  [[ -z "$status_filter" ]] || query+=(--data-urlencode "status=$status_filter")
  [[ -z "$cache_status" ]] || query+=(--data-urlencode "cacheStatus=$cache_status")
  [[ -z "$url_contains" ]] || query+=(--data-urlencode "urlContains=$url_contains")
  request GET "$logging_base/pullzones/$pull_zone_id/logs" "${query[@]}" | safe_logs
}

logs() {
  logs_response "$@"
}

log_usage_summary() {
  logs_response "$@" |
    jq -ce '
      {
        groups: (
          [.data[]? | {
            path: (.path // ""),
            cache_status: (.cacheStatus // ""),
            status_code: (.statusCode // 0),
            bytes_sent: (.bytesSent // 0)
          }]
          | sort_by([.path, .cache_status, .status_code])
          | group_by([.path, .cache_status, .status_code])
          | map({
              path: .[0].path,
              cache_status: .[0].cache_status,
              status_code: .[0].status_code,
              requests: length,
              bytes_sent: (map(.bytes_sent) | add // 0)
            })
          | sort_by(-.bytes_sent, -.requests, .path)
        ),
        pagination,
        query
      }
    '
}

origin_errors() {
  request GET "$origin_errors_base/$1/$2" |
    jq -ce '
      def without_query:
        if type == "string" then split("?")[0] else . end;
      {
        logs: [
          .logs[]?
          | (.log | fromjson? // {}) as $detail
          | {
              log_id: (.logId // ""),
              timestamp: (.timestamp // 0),
              request_url: (($detail.RequestUrl // "") | without_query),
              message: ($detail.Message // ""),
              error_code: ($detail.ErrorCode // .labels.ErrorCode // ""),
              status_code: (($detail.StatusCode // .labels.StatusCode // 0) | tonumber? // 0),
              server_zone: (.labels.ServerZone // "")
            }
        ]
      }
    '
}

billing_usage() {
  local account pull_zones
  account=$(request GET "$core_base/billing")
  pull_zones=$(request GET "$core_base/billing/summary")
  jq -nce --argjson account "$account" --argjson pull_zones "$pull_zones" '
    {
      account: {
        balance: ($account.Balance // 0),
        available_balance: ($account.AvailableBalance // 0),
        this_month_charges: ($account.ThisMonthCharges // 0),
        monthly_bandwidth_used: ($account.MonthlyBandwidthUsed // 0),
        monthly_charges_eu_us_traffic: ($account.MonthlyChargesEUTraffic // 0),
        monthly_charges_asia_traffic: ($account.MonthlyChargesASIATraffic // 0),
        monthly_charges_africa_traffic: ($account.MonthlyChargesAFTraffic // 0),
        monthly_charges_south_america_traffic: ($account.MonthlyChargesSATraffic // 0),
        monthly_charges_optimizer: ($account.MonthlyChargesOptimizer // 0),
        monthly_charges_storage: ($account.MonthlyChargesStorage // 0),
        monthly_charges_shield: ($account.MonthlyChargesShield // 0),
        monthly_charges_websockets: ($account.MonthlyChargesWebSockets // 0)
      },
      pull_zones: [
        $pull_zones[]?
        | {
            pull_zone_id: (.PullZoneId // 0),
            monthly_usage: (.MonthlyUsage // 0),
            monthly_bandwidth_used: (.MonthlyBandwidthUsed // 0)
          }
      ]
    }
  '
}

create_pull_zone() {
  local name=$1 origin_url=$2 tier=$3 enable_logging=$4 enable_cache_slice=$5 type
  case "$tier" in
    premium) type=0 ;;
    volume) type=1 ;;
    *) fail "unknown pull zone tier" ;;
  esac
  request_json POST "$core_base/pullzone" "$(
    jq -nc \
      --arg name "$name" \
      --arg origin "$origin_url" \
      --argjson type "$type" \
      --argjson logging "$enable_logging" \
      --argjson cache_slice "$enable_cache_slice" \
      '{Name:$name, OriginUrl:$origin, Type:$type, EnableLogging:$logging, LoggingIPAnonymizationEnabled:true, EnableCacheSlice:$cache_slice}'
  )" | safe_pull_zone
}

delete_pull_zone() {
  request DELETE "$core_base/pullzone/$1" >/dev/null
  jq -nce --argjson id "$1" '{deleted:true, pull_zone_id:$id}'
}

set_origin() {
  local body
  body=$(jq -nc \
    --arg origin "$2" \
    --arg host "$3" \
    --argjson verify "$4" \
    '{OriginUrl:$origin, VerifyOriginSSL:$verify} + (if $host == "" then {} else {OriginHostHeader:$host} end)')
  update_pull_zone "$1" "$body"
}

set_cache_ttl() {
  [[ "$2" != "unchanged" || "$3" != "unchanged" ]] || fail "at least one cache TTL must change"
  update_pull_zone "$1" "$(
    jq -nc --arg edge "$2" --arg browser "$3" '
      (if $edge == "unchanged" then {} else {CacheControlMaxAgeOverride:($edge | tonumber)} end)
      + (if $browser == "unchanged" then {} else {CacheControlPublicMaxAgeOverride:($browser | tonumber)} end)
    '
  )"
}

set_cache_behavior() {
  local key
  case "$2" in
    ignore_query_strings) key=IgnoreQueryStrings ;;
    cache_slice) key=EnableCacheSlice ;;
    smart_cache) key=EnableSmartCache ;;
    cache_error_responses) key=CacheErrorResponses ;;
    background_update) key=UseBackgroundUpdate ;;
    stale_while_offline) key=UseStaleWhileOffline ;;
    stale_while_updating) key=UseStaleWhileUpdating ;;
    request_coalescing) key=EnableRequestCoalescing ;;
    query_string_ordering) key=EnableQueryStringOrdering ;;
    *) fail "unknown cache behavior" ;;
  esac
  update_pull_zone "$1" "$(jq -nc --arg key "$key" --argjson enabled "$3" '{($key):$enabled}')"
}

set_origin_shield() {
  local body
  body=$(jq -nc --arg zone "$3" --argjson enabled "$2" \
    '{EnableOriginShield:$enabled} + (if $zone == "" then {} else {OriginShieldZoneCode:$zone} end)')
  update_pull_zone "$1" "$body"
}

set_logging() {
  local anonymization format
  case "$3" in
    last_octet) anonymization=0 ;;
    drop_all) anonymization=1 ;;
    *) fail "unknown log anonymization mode" ;;
  esac
  case "$4" in
    plain) format=0 ;;
    json) format=1 ;;
    *) fail "unknown log format" ;;
  esac
  update_pull_zone "$1" "$(
    jq -nc \
      --argjson enabled "$2" \
      --argjson anonymization "$anonymization" \
      --argjson format "$format" \
      '{EnableLogging:$enabled, LoggingIPAnonymizationEnabled:true, LogAnonymizationType:$anonymization, LogFormat:$format}'
  )"
}

hostname_change() {
  local verb=$1 pull_zone_id=$2 hostname=$3
  case "$verb" in
    add) mutate_pull_zone_resource POST "$pull_zone_id" addHostname "$(jq -nc --arg value "$hostname" '{Hostname:$value}')" ;;
    remove) mutate_pull_zone_resource DELETE "$pull_zone_id" removeHostname "$(jq -nc --arg value "$hostname" '{Hostname:$value}')" ;;
  esac
}

set_force_ssl() {
  mutate_pull_zone_resource POST "$1" setForceSSL "$(jq -nc --arg hostname "$2" --argjson enabled "$3" '{Hostname:$hostname, ForceSSL:$enabled}')"
}

referrer_change() {
  local resource=$1 pull_zone_id=$2 hostname=$3
  mutate_pull_zone_resource POST "$pull_zone_id" "$resource" "$(jq -nc --arg value "$hostname" '{Hostname:$value}')"
}

blocked_ip_change() {
  local resource=$1 pull_zone_id=$2 address=$3
  mutate_pull_zone_resource POST "$pull_zone_id" "$resource" "$(jq -nc --arg value "$address" '{BlockedIp:$value}')"
}

purge_url() {
  local url=${BUNNY_PURGE_URL:?BUNNY_PURGE_URL is required}
  request POST "$core_base/purge" -G \
    --data-urlencode "url=$url" \
    --data-urlencode "async=$1" \
    --data-urlencode "exactPath=$2" >/dev/null
  jq -nce --arg url "${url%%\?*}" '{purged:true, scope:"url", url:$url}'
}

purge_tag() {
  request_json POST "$core_base/pullzone/$1/purgeCache" "$(jq -nc --arg tag "$2" '{CacheTag:$tag}')" >/dev/null
  jq -nce --argjson id "$1" --arg tag "$2" '{purged:true, scope:"tag", pull_zone_id:$id, cache_tag:$tag}'
}

purge_all_cache() {
  request_json POST "$core_base/pullzone/$1/purgeCache" '{}' >/dev/null
  jq -nce --argjson id "$1" '{purged:true, scope:"pull_zone", pull_zone_id:$id}'
}

require_key
validate_bases

command=${1:-}
shift || true
case "$command" in
  list-pull-zones) list_pull_zones "$@" ;;
  get-pull-zone) get_pull_zone "$@" ;;
  list-regions) list_regions "$@" ;;
  statistics) statistics "$@" ;;
  optimizer-statistics) product_statistics "$1" optimizer "$2" "$3" "$4" ;;
  origin-shield-statistics) origin_shield_statistics "$@" ;;
  safehop-statistics) product_statistics "$1" safehop "$2" "$3" "$4" ;;
  logs) logs "$@" ;;
  log-usage-summary) log_usage_summary "$@" ;;
  origin-errors) origin_errors "$@" ;;
  billing-usage) billing_usage ;;
  create-pull-zone) create_pull_zone "$@" ;;
  delete-pull-zone) delete_pull_zone "$@" ;;
  set-origin) set_origin "$@" ;;
  set-cache-ttl) set_cache_ttl "$@" ;;
  set-cache-behavior) set_cache_behavior "$@" ;;
  set-origin-shield) set_origin_shield "$@" ;;
  set-logging) set_logging "$@" ;;
  add-hostname) hostname_change add "$@" ;;
  remove-hostname) hostname_change remove "$@" ;;
  set-force-ssl) set_force_ssl "$@" ;;
  add-allowed-referrer) referrer_change addAllowedReferrer "$@" ;;
  remove-allowed-referrer) referrer_change removeAllowedReferrer "$@" ;;
  add-blocked-referrer) referrer_change addBlockedReferrer "$@" ;;
  remove-blocked-referrer) referrer_change removeBlockedReferrer "$@" ;;
  add-blocked-ip) blocked_ip_change addBlockedIp "$@" ;;
  remove-blocked-ip) blocked_ip_change removeBlockedIp "$@" ;;
  purge-url) purge_url "$@" ;;
  purge-tag) purge_tag "$@" ;;
  purge-all-cache) purge_all_cache "$@" ;;
  *) fail "unknown bunnycdn operation" ;;
esac

#!/bin/sh
set -eu

mode=$1
project=$2
dataset=$3
billing_account=$4
days=$5
row_limit=$6
max_scan_gb=$7
service_filter=$8

# The loader already bounds every argument, but the export table reference is the
# one value a query parameter cannot carry — BigQuery parameterizes values, never
# identifiers — so its charset is re-checked here before it reaches authored SQL.
case "$project" in
  "" | *[!a-z0-9-]*)
    printf '%s\n' "invalid BigQuery project" >&2
    exit 2
    ;;
esac
case "$dataset" in
  "" | *[!A-Za-z0-9_]*)
    printf '%s\n' "invalid BigQuery dataset" >&2
    exit 2
    ;;
esac
case "$billing_account" in
  "" | *[!A-Z0-9-]*)
    printf '%s\n' "invalid billing account" >&2
    exit 2
    ;;
esac

access_token=$(gcloud auth print-access-token --quiet)
api_base=${CLOUDSDK_API_ENDPOINT_OVERRIDES_BIGQUERY:-https://bigquery.googleapis.com}
api_base=${api_base%/}

case "$api_base" in
  https://*) ;;
  *)
    printf '%s\n' "BigQuery API endpoint must use HTTPS" >&2
    exit 2
    ;;
esac

umask 077
tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-gcp-billing.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM

# The token rides a curl config document on stdin so it never reaches argv.
auth_config() {
  printf 'header = "Authorization: Bearer %s"\n' "$access_token"
  printf 'header = "Content-Type: application/json"\n'
}

# A billing account exports to the standard table or to the detailed one that
# adds resource-level rows, and an account may have turned on either. Every
# column these queries read exists in both, so the export that is actually
# there is the one to query — asking for a fixed name answers a fleet that
# enabled the other kind with a 404 it can do nothing about.
account_suffix=$(printf '%s' "$billing_account" | tr -- '-' '_')
standard_table="gcp_billing_export_v1_$account_suffix"
detailed_table="gcp_billing_export_resource_v1_$account_suffix"

table_id=""
for candidate in "$standard_table" "$detailed_table"; do
  if auth_config | curl -q --config - --fail-with-body --silent --show-error --globoff \
    --proto '=https' --connect-timeout 10 --max-time 30 --max-filesize 1048576 \
    --output "$tmp/table.json" \
    "$api_base/bigquery/v2/projects/$project/datasets/$dataset/tables/$candidate?fields=tableReference" \
    2>"$tmp/table.err"; then
    table_id=$candidate
    break
  fi
done

if [ -z "$table_id" ]; then
  # The last probe's own words separate an export that was never enabled from a
  # dataset the principal cannot read.
  detail=$(jq -r '.error.message // empty' "$tmp/table.json" 2>/dev/null || true)
  if [ -z "$detail" ]; then
    detail=$(tail -n 1 "$tmp/table.err" 2>/dev/null || true)
  fi
  printf '%s\n' "no readable billing export table in $project.$dataset — looked for $standard_table (standard export) then $detailed_table (detailed export): ${detail:-not found}" >&2
  exit 1
fi

table="$project.$dataset.$table_id"
max_bytes=$((max_scan_gb * 1073741824))

# Credits post as a repeated field and are negative, so net cost is the gross
# charge plus their sum — the number the invoice eventually shows. BigQuery
# renders a FLOAT64 past 1e7 with an exponent ("1.2436E7"), which is not a
# number an operator or a model should have to decode, so every amount is cast
# to NUMERIC and arrives as a plain decimal at any size.
credits='SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0))'
amounts="CAST(ROUND(SUM(cost), 6) AS NUMERIC) AS gross_cost,
           CAST(ROUND($credits, 6) AS NUMERIC) AS credits,
           CAST(ROUND(SUM(cost) + $credits, 6) AS NUMERIC) AS net_cost"
window='usage_start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL @days DAY)'
service_clause='(@service = "" OR service.description = @service)'

case "$mode" in
  cost-by-service)
    sql="SELECT
           service.description AS service,
           $amounts,
           ANY_VALUE(currency) AS currency
         FROM \`$table\`
         WHERE $window AND $service_clause
         GROUP BY service
         ORDER BY net_cost DESC
         LIMIT @row_limit"
    ;;

  cost-by-project)
    sql="SELECT
           IFNULL(project.id, '(unattributed)') AS project_id,
           ANY_VALUE(project.name) AS project_name,
           $amounts,
           ANY_VALUE(currency) AS currency
         FROM \`$table\`
         WHERE $window AND $service_clause
         GROUP BY project_id
         ORDER BY net_cost DESC
         LIMIT @row_limit"
    ;;

  cost-by-sku)
    sql="SELECT
           service.description AS service,
           sku.description AS sku,
           $amounts,
           ANY_VALUE(currency) AS currency,
           CAST(ROUND(SUM(usage.amount_in_pricing_units), 6) AS NUMERIC) AS usage_amount,
           ANY_VALUE(usage.pricing_unit) AS usage_unit
         FROM \`$table\`
         WHERE $window AND $service_clause
         GROUP BY service, sku
         ORDER BY net_cost DESC
         LIMIT @row_limit"
    ;;

  cost-daily-trend)
    sql="SELECT
           DATE(usage_start_time) AS usage_date,
           $amounts,
           ANY_VALUE(currency) AS currency
         FROM \`$table\`
         WHERE $window AND $service_clause
         GROUP BY usage_date
         ORDER BY usage_date DESC
         LIMIT @row_limit"
    ;;

  export-freshness)
    # A bare TIMESTAMP comes back as epoch seconds ("1.785853200971549E9"), so
    # every one is formatted here — this action's whole job is telling an
    # operator how stale the export is.
    sql="SELECT
           FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', MAX(export_time)) AS latest_export_time,
           TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(export_time), HOUR) AS export_lag_hours,
           FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', MAX(usage_end_time)) AS latest_usage_end_time,
           FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', MIN(usage_start_time)) AS earliest_usage_start_time,
           COUNT(*) AS rows_in_window
         FROM \`$table\`
         WHERE $window"
    ;;

  *)
    printf '%s\n' "unsupported billing operation: $mode" >&2
    exit 2
    ;;
esac

jq -nc \
  --arg query "$sql" \
  --arg days "$days" \
  --arg row_limit "$row_limit" \
  --arg service "$service_filter" \
  --arg max_bytes "$max_bytes" \
  '{
     query: $query,
     useLegacySql: false,
     maximumBytesBilled: $max_bytes,
     maxResults: ($row_limit | tonumber),
     timeoutMs: 60000,
     queryParameters: [
       {name: "days", parameterType: {type: "INT64"}, parameterValue: {value: $days}},
       {name: "row_limit", parameterType: {type: "INT64"}, parameterValue: {value: $row_limit}},
       {name: "service", parameterType: {type: "STRING"}, parameterValue: {value: $service}}
     ]
   }' >"$tmp/request.json"

if ! auth_config | curl -q --config - --fail-with-body --silent --show-error --globoff \
  --proto '=https' --connect-timeout 10 --max-time 120 --max-filesize 8388608 \
  --request POST --data-binary "@$tmp/request.json" \
  --output "$tmp/response.json" \
  "$api_base/bigquery/v2/projects/$project/queries"; then
  # A capped scan, a missing export table, and a denied dataset all arrive as a
  # structured error, and its message is the only thing that tells them apart.
  # An empty or unparsable body falls back rather than failing silently.
  message=$(jq -r '.error.message // empty' "$tmp/response.json" 2>/dev/null || true)
  printf '%s\n' "${message:-BigQuery rejected the query}" >&2
  exit 1
fi

# An incomplete job returns no rows. Reporting that as an empty result would read
# as "nothing was spent", so it fails loudly instead.
if [ "$(jq -r '.jobComplete // false' "$tmp/response.json")" != true ]; then
  printf '%s\n' "BigQuery did not finish the query within the request timeout; narrow days or raise max_scan_gb" >&2
  exit 1
fi

jq -ce --arg table "$table" '
  (.schema.fields // [] | map(.name)) as $names |
  {
    table: $table,
    rows: [
      (.rows // [])[] |
      [$names, [.f[].v]] | transpose | map({(.[0]): .[1]}) | add
    ],
    total_rows: ((.totalRows // "0") | tonumber),
    total_bytes_processed: ((.totalBytesProcessed // "0") | tonumber),
    cache_hit: (.cacheHit // false)
  }' "$tmp/response.json"

#!/bin/sh
set -eu

mode=$1
project=$2

project_with_jq() {
  filter=$1
  shift
  umask 077
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  "$@" >"$tmp"
  jq -e "$filter" "$tmp"
}

# Query Insights has no Cloud SQL Admin API surface and no gcloud command — it
# publishes to Cloud Monitoring — so this one mode talks to the Monitoring REST
# API directly instead of going through gcloud like every other mode here.
query_insights() {
  instance=$1
  database=$2
  metric=$3
  window_minutes=$4
  top_n=$5

  case "$metric" in
    execution_time | io_time | lock_time)
      metric_leaf=$metric
      reducer=REDUCE_SUM
      unit=us
      ;;
    row_count | shared_blk_access_count)
      metric_leaf=$metric
      reducer=REDUCE_SUM
      unit=count
      ;;
    # latencies is a CUMULATIVE DISTRIBUTION: ALIGN_PERCENTILE_* is rejected on
    # that pair, so the percentile comes from the cross-series reducer instead.
    latency_p50)
      metric_leaf=latencies
      reducer=REDUCE_PERCENTILE_50
      unit=us
      ;;
    latency_p95)
      metric_leaf=latencies
      reducer=REDUCE_PERCENTILE_95
      unit=us
      ;;
    latency_p99)
      metric_leaf=latencies
      reducer=REDUCE_PERCENTILE_99
      unit=us
      ;;
    *)
      printf '%s\n' "unsupported query insights metric: $metric" >&2
      exit 2
      ;;
  esac

  access_token=$(gcloud auth print-access-token --quiet)
  api_base=${CLOUDSDK_API_ENDPOINT_OVERRIDES_MONITORING:-https://monitoring.googleapis.com}
  api_base=${api_base%/}

  case "$api_base" in
    https://*) ;;
    *)
      printf '%s\n' "Monitoring API endpoint must use HTTPS" >&2
      exit 2
      ;;
  esac

  window_seconds=$((window_minutes * 60))
  end_epoch=$(date -u +%s)
  start_epoch=$((end_epoch - window_seconds))
  start_time=$(date -u -d "@$start_epoch" +%Y-%m-%dT%H:%M:%SZ)
  end_time=$(date -u -d "@$end_epoch" +%Y-%m-%dT%H:%M:%SZ)

  filter="metric.type = \"cloudsql.googleapis.com/database/postgresql/insights/perquery/$metric_leaf\""
  filter="$filter AND resource.labels.resource_id = \"$project:$instance\""
  if [ -n "$database" ]; then
    filter="$filter AND resource.labels.database = \"$database\""
  fi

  umask 077
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-gcp-cloudsql.XXXXXX")
  trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
  : >"$tmp/series.jsonl"

  auth_config() {
    printf 'header = "Authorization: Bearer %s"\n' "$access_token"
    printf 'header = "X-Goog-User-Project: %s"\n' "$project"
  }

  page_token=""
  pages=0
  complete=true
  while :; do
    # One alignment period spanning the whole window collapses each series to a
    # single point, which is what makes a ranking well defined.
    set -- --get \
      --data-urlencode "filter=$filter" \
      --data-urlencode "interval.startTime=$start_time" \
      --data-urlencode "interval.endTime=$end_time" \
      --data-urlencode "aggregation.alignmentPeriod=${window_seconds}s" \
      --data-urlencode "aggregation.perSeriesAligner=ALIGN_DELTA" \
      --data-urlencode "aggregation.crossSeriesReducer=$reducer" \
      --data-urlencode "aggregation.groupByFields=metric.label.query_hash" \
      --data-urlencode "aggregation.groupByFields=metric.label.querystring" \
      --data-urlencode "view=FULL" \
      --data-urlencode "pageSize=2000"
    if [ -n "$page_token" ]; then
      set -- "$@" --data-urlencode "pageToken=$page_token"
    fi

    if ! auth_config | curl -q --config - --fail-with-body --silent --show-error \
      --globoff --proto '=https' --connect-timeout 10 --max-time 60 \
      --max-filesize 8388608 --output "$tmp/page.json" "$@" \
      "$api_base/v3/projects/$project/timeSeries"; then
      message=$(jq -r '.error.message // empty' "$tmp/page.json" 2>/dev/null || true)
      printf '%s\n' "${message:-Monitoring rejected the query insights request}" >&2
      exit 1
    fi

    jq -c '(.timeSeries // [])[]' "$tmp/page.json" >>"$tmp/series.jsonl"
    page_token=$(jq -r '.nextPageToken // ""' "$tmp/page.json")
    pages=$((pages + 1))
    [ -n "$page_token" ] || break
    # Ranking client-side means a partial fetch would silently mis-rank, so the
    # page budget is reported rather than hidden.
    if [ "$pages" -ge 10 ]; then
      complete=false
      break
    fi
  done

  jq -sce \
    --arg project "$project" \
    --arg instance "$instance" \
    --arg database "$database" \
    --arg metric "$metric" \
    --arg unit "$unit" \
    --arg start_time "$start_time" \
    --arg end_time "$end_time" \
    --argjson top_n "$top_n" \
    --argjson complete "$complete" '
      [
        .[] |
        {
          query_hash: .metric.labels.query_hash,
          querystring: .metric.labels.querystring,
          value: ((.points // [])[0].value |
                  (.int64Value // .doubleValue // 0) | tonumber)
        }
      ] as $series |
      {
        project: $project,
        instance: $instance,
        database: (if $database == "" then null else $database end),
        metric: $metric,
        unit: $unit,
        interval: {start_time: $start_time, end_time: $end_time},
        series_count: ($series | length),
        ranking_complete: $complete,
        top: [
          $series | sort_by(-.value) | .[0:$top_n] | to_entries[] |
          .value + {rank: (.key + 1)}
        ]
      } |
      # An empty result is indistinguishable from a healthy idle window, so name
      # the other causes rather than letting it read as "no slow queries".
      if .series_count == 0 then
        .note = "no Query Insights data for this instance in this window — check that query_insights_enabled is on, that the window is after it was enabled, and that the instance and database names are exact"
      else . end
    ' "$tmp/series.jsonl"
}

instance_projection='
  {
    name,
    project,
    region,
    gceZone,
    secondaryGceZone,
    databaseVersion,
    state,
    instanceType,
    connectionName,
    ipAddresses,
    ipv6Address,
    dnsName,
    primaryDnsName,
    writeEndpoint,
    pscServiceAttachmentLink,
    serverCaMode,
    serverCaPool,
    satisfiesPzi,
    masterInstanceName,
    replicaNames,
    failoverReplica: (
      if .failoverReplica then {
        name: .failoverReplica.name,
        available: .failoverReplica.available
      } else null end
    ),
    settings: {
      tier: .settings.tier,
      edition: .settings.edition,
      availabilityType: .settings.availabilityType,
      activationPolicy: .settings.activationPolicy,
      diskType: .settings.dataDiskType,
      diskSizeGb: .settings.dataDiskSizeGb,
      diskAutoresize: .settings.storageAutoResize,
      diskAutoresizeLimit: .settings.storageAutoResizeLimit,
      deletionProtectionEnabled: .settings.deletionProtectionEnabled,
      backupConfiguration: (
        if .settings.backupConfiguration then {
          enabled: .settings.backupConfiguration.enabled,
          location: .settings.backupConfiguration.location,
          pointInTimeRecoveryEnabled: .settings.backupConfiguration.pointInTimeRecoveryEnabled,
          transactionLogRetentionDays: .settings.backupConfiguration.transactionLogRetentionDays,
          retainedBackups: .settings.backupConfiguration.backupRetentionSettings.retainedBackups,
          retentionUnit: .settings.backupConfiguration.backupRetentionSettings.retentionUnit,
          startTime: .settings.backupConfiguration.startTime
        } else null end
      ),
      ipConfiguration: (
        if .settings.ipConfiguration then {
          ipv4Enabled: .settings.ipConfiguration.ipv4Enabled,
          privateNetwork: .settings.ipConfiguration.privateNetwork,
          requireSsl: .settings.ipConfiguration.requireSsl,
          sslMode: .settings.ipConfiguration.sslMode,
          allocatedIpRange: .settings.ipConfiguration.allocatedIpRange,
          pscEnabled: .settings.ipConfiguration.pscConfig.pscEnabled,
          authorizedNetworks: [
            (.settings.ipConfiguration.authorizedNetworks // [])[] |
            {value, expirationTime}
          ]
        } else null end
      ),
      maintenanceWindow: .settings.maintenanceWindow,
      insightsConfig: .settings.insightsConfig,
      databaseFlagNames: [(.settings.databaseFlags // [])[] | .name]
    }
  }
'

operation_projection='
  {
    name,
    operationType,
    status,
    targetId,
    targetProject,
    targetLink,
    user,
    insertTime,
    startTime,
    endTime,
    errorCodes: [(.error.errors // [])[] | .code],
    apiWarningCode: .apiWarning.code
  }
'

case "$mode" in
  instances)
    project_with_jq "map($instance_projection)" \
      gcloud sql instances list \
      "--project=$project" "--limit=$3" --format=json --quiet
    ;;
  instance-describe)
    project_with_jq "$instance_projection" \
      gcloud sql instances describe "$3" \
      "--project=$project" --format=json --quiet
    ;;
  databases)
    project_with_jq \
      'map({name, instance, project, charset, collation, sqlserverDatabaseDetails})' \
      gcloud sql databases list \
      "--instance=$3" "--project=$project" "--limit=$4" --format=json --quiet
    ;;
  users)
    project_with_jq \
      'map({name, host, instance, project, type, passwordPolicy})' \
      gcloud sql users list \
      "--instance=$3" "--project=$project" "--limit=$4" --format=json --quiet
    ;;
  backups)
    project_with_jq \
      'map({
        id,
        instance,
        project,
        status,
        type,
        backupKind,
        databaseVersion,
        location,
        windowStartTime,
        startTime,
        endTime,
        enqueuedTime
      })' \
      gcloud sql backups list \
      "--instance=$3" "--project=$project" "--limit=$4" --format=json --quiet
    ;;
  operations)
    project_with_jq "map($operation_projection)" \
      gcloud sql operations list \
      "--instance=$3" "--project=$project" "--limit=$4" --format=json --quiet
    ;;
  instance-restart)
    project_with_jq "$operation_projection" \
      gcloud sql instances restart "$3" \
      "--project=$project" --async --format=json --quiet
    ;;
  instance-failover)
    project_with_jq "$operation_projection" \
      gcloud sql instances failover "$3" \
      "--project=$project" --async --format=json --quiet
    ;;
  operation-describe)
    project_with_jq "$operation_projection" \
      gcloud sql operations describe "$3" \
      "--project=$project" --format=json --quiet
    ;;
  query-insights)
    query_insights "$3" "$4" "$5" "$6" "$7"
    ;;
  server-ca-certs)
    project_with_jq \
      'map({
        certSerialNumber,
        commonName,
        createTime,
        expirationTime,
        instance,
        sha1Fingerprint,
        type
      })' \
      gcloud sql ssl server-ca-certs list \
      "--instance=$3" "--project=$project" "--limit=$4" --format=json --quiet
    ;;
  *)
    echo "unsupported Cloud SQL operation" >&2
    exit 2
    ;;
esac

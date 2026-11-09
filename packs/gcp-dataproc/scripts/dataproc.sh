#!/bin/bash
set -euo pipefail

mode=$1 project=$2 region=$3
api=${CLOUDSDK_API_ENDPOINT_OVERRIDES_DATAPROC:-https://dataproc.googleapis.com}
api=${api%/}
if [[ ! $api =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
  printf '%s\n' 'Dataproc endpoint must be an HTTPS origin without credentials, path or query.' >&2
  exit 2
fi
umask 077
tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-dataproc.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
if ! access=$(gcloud auth print-access-token --quiet 2>"$tmp/auth-error"); then
  printf '%s\n' 'Could not obtain a gcloud access credential; check the attached service account or configured gcloud identity.' >&2
  exit 1
fi
if [[ ! $access =~ ^[A-Za-z0-9._~+/-]+=*$ ]]; then
  printf '%s\n' 'gcloud returned an invalid access credential.' >&2
  exit 1
fi

# All projection functions use core jq, including on hosts without Oniguruma.
# Names used for a later operation are preserved exactly or rejected, never
# clipped into a different target. Free-text fields are explicitly bounded.
readonly projection='
def object: if type == "object" then . else error("expected a Dataproc object") end;
def text($n):
  (if . == null then "" elif type == "string" then . else error("expected a Dataproc string") end)
  | explode | map(if . <= 31 or (. >= 127 and . <= 159) then 32 else . end) | implode
  | if length <= $n then . else .[:$n - 1] + "…" end;
def identifier($n):
  if type != "string" or length == 0 or length > $n then error("invalid Dataproc identifier")
  elif (explode | all(.[]; (. >= 48 and . <= 57) or (. >= 65 and . <= 90) or (. >= 97 and . <= 122) or . == 45 or . == 95)) then .
  else error("invalid Dataproc identifier") end;
def basename($n):
  if . == null then "" elif type == "string" then split("/") | last | text($n)
  else error("expected a Dataproc URI") end;
def integer:
  if . == null then null elif type == "number" and floor == . and . >= 0 and . <= 2147483647 then .
  else error("expected a nonnegative Dataproc int32") end;
def fraction:
  if . == null then null elif type == "number" and . >= 0 and . <= 1 then .
  else error("expected a Dataproc factor from zero to one") end;
def list($name):
  if has($name) | not then [] elif (.[$name] | type) == "array" then .[$name]
  else error("expected a Dataproc collection array") end;
def cursor:
  (. // "") as $v
  | if ($v | type) != "string" then error("expected a Dataproc continuation string")
    elif $v == "" then {value: null, omitted: false, more: false}
    elif ($v | length) <= 1024 and ($v | explode | all(.[];
      (. >= 48 and . <= 57) or (. >= 65 and . <= 90) or (. >= 97 and . <= 122) or
      . == 43 or . == 45 or . == 46 or . == 47 or . == 61 or . == 95 or . == 126))
    then {value: $v, omitted: false, more: true}
    else {value: null, omitted: true, more: true} end;
def cluster_summary:
  object | {name: (.clusterName | identifier(51)), state: (.status.state | text(24)),
    state_started: (.status.stateStartTime | text(40)),
    workers: (.config.workerConfig.numInstances | integer), secondary_workers: (.config.secondaryWorkerConfig.numInstances | integer),
    image: (.config.softwareConfig.imageVersion | text(32))};
def job_summary:
  object | {id: (.reference.jobId | identifier(100)), cluster: (.placement.clusterName | identifier(51)),
    state: (.status.state | text(24)), state_started: (.status.stateStartTime | text(40)),
    type: (if has("pysparkJob") then "pyspark" elif has("sparkJob") then "spark" elif has("sparkSqlJob") then "spark_sql"
      elif has("hadoopJob") then "hadoop" elif has("hiveJob") then "hive" elif has("pigJob") then "pig"
      elif has("prestoJob") then "presto" elif has("trinoJob") then "trino" elif has("flinkJob") then "flink" else "other" end)};
def operation_summary:
  object | {id: (.name | if type == "string" then split("/") | last | identifier(40) else error("expected an operation name") end),
    done: (if has("done") then .done | if type == "boolean" then . else error("expected operation done boolean") end else false end),
    cluster: (.metadata.clusterName | text(51)), type: (.metadata.operationType | text(24)),
    state: (.metadata.status.state | text(24)), state_started: (.metadata.status.stateStartTime | text(40)),
    error_code: (.error.code | integer)};
def bounds: {min: (.minInstances | integer), max: (.maxInstances | integer), weight: (.weight | integer)};
def policy_summary:
  object | {id: (.id | identifier(50)), primary: (.workerConfig | bounds), secondary: (.secondaryWorkerConfig | bounds),
    cooldown: (.basicAlgorithm.cooldownPeriod | text(32))};
def metric_entries:
  if . == null then [] else object | to_entries | map(
    if (.value | type) != "string" or (.value | length) > 20 or
      (.value | ltrimstr("-") | length == 0 or (explode | all(.[]; . >= 48 and . <= 57) | not))
    then error("expected Dataproc int64 metric strings")
    else {name: (.key | text(48)), name_truncated: ((.key | length) > 48), value: .value} end) end;
def page($family; $kind; $size):
  object | (.nextPageToken | cursor) as $cursor | list($family) as $rows
  | {items: [$rows[:$size][] | if $kind == "clusters" then cluster_summary elif $kind == "jobs" then job_summary
       elif $kind == "operations" then operation_summary else policy_summary end],
     returned_count: ([$rows | length, $size] | min), omitted_in_response: ([($rows | length) - $size, 0] | max),
     more_available: $cursor.more, next_page_cursor: $cursor.value, cursor_omitted: $cursor.omitted,
     unreachable_count: (if $kind == "jobs" then list("unreachable") | length else 0 end)};
'

request() {
  local method=$1 path=$2 body=$3 url key value rc=0
  shift 3
  url="$api/v1/projects/$project/regions/$region/$path"
  local separator='?' args=()
  for pair in "$@"; do
    key=${pair%%=*} value=${pair#*=}
    url+="$separator$key=$(jq -rn --arg value "$value" '$value | @uri')"
    separator='&'
  done
  if [[ -n $body ]]; then
    printf '%s' "$body" >"$tmp/body"
    args+=(--header 'Content-Type: application/json' --data-binary "@$tmp/body")
  fi
  # Dataproc already names the resource project. Do not override its quota
  # project and add an unrelated serviceusage.services.use requirement.
  local statuses=()
  if printf 'header = "Authorization: Bearer %s"\n' "$access" |
    curl -q --config - --fail-with-body --silent --show-error --globoff --proto '=https' \
    --connect-timeout 10 --max-time 45 --max-redirs 0 --max-filesize 4194304 \
    --request "$method" "${args[@]}" "$url" 2>"$tmp/http-error" |
    head -c 4194305 >"$tmp/response"; then
    statuses=("${PIPESTATUS[@]}")
  else
    statuses=("${PIPESTATUS[@]}")
  fi
  # Before curl 8.4, --max-filesize does not cap unknown-length transfers.
  # Keep one overflow byte independently, terminate the producer at the cap,
  # and inspect every pipeline status instead of accepting a partial body.
  if (($(wc -c <"$tmp/response") > 4194304)); then
    printf '%s\n' 'Dataproc response exceeds the 4 MiB byte budget.' >&2
    exit 1
  fi
  if ((statuses[0] != 0 || statuses[2] != 0)); then
    printf '%s\n' 'Could not capture the bounded Dataproc response.' >&2
    exit 1
  fi
  rc=${statuses[1]}
  if ((rc != 0)); then
    printf 'Dataproc API request failed (client exit %s).\n' "$rc" >&2
    # Error envelopes can contain submitted payloads and provider internals.
    # Preserve only the bounded public code/status/message, never raw bodies.
    jq -ce "$projection"'{error: {code: (.error.code | integer), status: (.error.status | text(64)), message: (.error.message | text(256))}}' \
      "$tmp/response" >&2 2>/dev/null || true
    exit "$rc"
  fi
}

emit() {
  local filter=$1
  shift
  jq -ce "$@" "$projection$filter" "$tmp/response"
}

case "$mode" in
  clusters_list|operations_list|autoscaling_policies_list)
    size=$4 cursor=$5
    case "$mode" in
      clusters_list) family=clusters kind=clusters ;;
      operations_list) family=operations kind=operations ;;
      autoscaling_policies_list) family=autoscalingPolicies kind=policies ;;
    esac
    query=("pageSize=$size")
    [[ -z $cursor ]] || query+=("pageToken=$cursor")
    request GET "$family" '' "${query[@]}"
    emit 'page($family; $kind; $size)' --arg family "$kind" --arg kind "$kind" --argjson size "$size"
    ;;
  jobs_list)
    size=$4 cursor=$5 cluster_filter=$6 state=$7 start_time=$8 end_time=$9
    invalid_query() {
      printf '%s\n' 'Invalid Dataproc history query or continuation; start a new query with an empty page_cursor.' >&2
      exit 2
    }
    if [[ -n $start_time || -n $end_time ]]; then
      for timestamp in "$start_time" "$end_time"; do
        [[ $timestamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || invalid_query
        [[ $(date -u -d "$timestamp" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) == "$timestamp" ]] || invalid_query
      done
      [[ $start_time < $end_time ]] || invalid_query
    fi
    fingerprint=$(jq -nc --arg endpoint "$api" --arg project "$project" --arg region "$region" \
      --arg cluster "$cluster_filter" --arg state "$state" --arg start "$start_time" --arg until_time "$end_time" \
      --argjson size "$size" '[$endpoint,$project,$region,$cluster,$state,$start,$until_time,$size]' | sha256sum)
    fingerprint=${fingerprint%% *}
    provider_cursor='' offset=0 previous_hash='-'
    if [[ -n $cursor ]]; then
      [[ ${#cursor} -le 1280 && $cursor == v1.* && $cursor != *[!A-Za-z0-9+./=_~-]* ]] || invalid_query
      rest=${cursor#v1.}
      [[ ${rest%%.*} == "$fingerprint" ]] || invalid_query
      rest=${rest#*.} offset=${rest%%.*}
      rest=${rest#*.} previous_hash=${rest%%.*} provider_cursor=${rest#*.}
      [[ $offset =~ ^(0|[1-9][0-9]?)$ && ${#provider_cursor} -le 1024 ]] || invalid_query
      if ((offset > 0)); then
        [[ $previous_hash =~ ^[a-f0-9]{64}$ ]] || invalid_query
      else
        [[ $previous_hash == '-' && -n $provider_cursor ]] || invalid_query
      fi
    fi
    # clusterName resolves a live cluster and fails after deletion. Scan one
    # bounded regional provider page and select retained placement names here.
    # Resume within that page when the six-row response fills, never drop matches.
    provider_size=$size
    [[ -z $cluster_filter ]] || provider_size=100
    query=("pageSize=$provider_size")
    [[ -z $provider_cursor ]] || query+=("pageToken=$provider_cursor")
    filter=''
    [[ $state == ALL ]] || filter="status.state = $state"
    if [[ -n $start_time ]]; then
      [[ -z $filter ]] || filter+=' AND '
      filter+="insertTime >= \"$start_time\" AND insertTime <= \"$end_time\""
    fi
    [[ -z $filter ]] || query+=("filter=$filter")
    request GET jobs '' "${query[@]}"
    page_hash=$(sha256sum "$tmp/response") page_hash=${page_hash%% *}
    if ((offset > 0)); then
      [[ $previous_hash == "$page_hash" ]] || invalid_query
    fi
    emit '
      object | list("jobs") as $rows | (.nextPageToken | cursor) as $next
      | if ($rows | length) > $provider_size or $offset > ($rows | length)
        then error("invalid Dataproc provider page") else . end
      | [range($offset; $rows | length) | select($cluster == "" or $rows[.].placement.clusterName == $cluster)] as $matches
      | $matches[:$size] as $selected
      | (($matches | length) > $size) as $within_page
      | (if $within_page then ($selected[-1] + 1) else 0 end) as $next_offset
      | (if $within_page then $provider_cursor else $next.value end) as $token
      | {items: [$selected[] | $rows[.] | job_summary], returned_count: ($selected | length),
          scanned_count: (($rows | length) - $offset), omitted_in_response: 0,
          more_available: ($within_page or $next.more), cursor_omitted: (($within_page | not) and $next.omitted),
          next_page_cursor: (if $within_page or $next.value != null
            then "v1." + $fingerprint + "." + ($next_offset | tostring) + "." +
              (if $within_page then $page_hash else "-" end) + "." + $token else null end),
          unreachable_count: (list("unreachable") | length)}' \
      --arg cluster "$cluster_filter" --arg provider_cursor "$provider_cursor" --arg fingerprint "$fingerprint" \
      --arg page_hash "$page_hash" --argjson offset "$offset" --argjson size "$size" --argjson provider_size "$provider_size"
    ;;
  cluster_details)
    request GET "clusters/$4" ''
    emit 'object | cluster_summary + {uuid: (.clusterUuid | identifier(36)),
      master_machine: (.config.masterConfig.machineTypeUri | basename(64)),
      worker_machine: (.config.workerConfig.machineTypeUri | basename(64)),
      zone: (.config.gceClusterConfig.zoneUri | basename(64)),
      service_account: (.config.gceClusterConfig.serviceAccount | text(128)),
      autoscaling_policy: (.config.autoscalingConfig.policyUri | if . == null or . == "" then "" elif type == "string" then split("/") | last | identifier(50) else error("expected an autoscaling policy URI") end),
      idle_delete_ttl: (.config.lifecycleConfig.idleDeleteTtl | text(32)), auto_delete_time: (.config.lifecycleConfig.autoDeleteTime | text(40))}'
    ;;
  cluster_metrics)
    request GET "clusters/$4" ''
    emit 'object | (.metrics.hdfsMetrics | metric_entries) as $hdfs | (.metrics.yarnMetrics | metric_entries) as $yarn
      | {cluster: (.clusterName | identifier(51)), available: (($hdfs | length) + ($yarn | length) > 0),
         hdfs: $hdfs[:8], yarn: $yarn[:8], omitted: {hdfs: ([($hdfs | length) - 8, 0] | max), yarn: ([($yarn | length) - 8, 0] | max)}}'
    ;;
  job_details)
    request GET "jobs/$4" ''
    emit 'object | list("yarnApplications") as $apps | job_summary + {uuid: (.placement.clusterUuid | if . == null then null else identifier(36) end),
      substate: (.status.substate | text(24)), yarn: [$apps[:4][] | object | {name: (.name | text(96)), state: (.state | text(24)), progress: (if .progress == null then null elif (.progress | type) == "number" and .progress >= 0 and .progress <= 100 then .progress else error("invalid YARN progress") end)}],
      yarn_omitted: ([($apps | length) - 4, 0] | max)}'
    ;;
  job_errors)
    request GET "jobs/$4" ''
    emit 'object | list("statusHistory") as $history | {id: (.reference.jobId | identifier(100)), state: (.status.state | text(24)),
      details: (.status.details | text(512)), history: [$history[-4:][] | object | {state: (.state | text(24)), started: (.stateStartTime | text(40))}],
      history_omitted: ([($history | length) - 4, 0] | max)}'
    ;;
  operation_details)
    request GET "operations/$4" ''
    emit 'object | operation_summary + {message: (.error.message | text(512))}'
    ;;
  autoscaling_policy_details)
    request GET "autoscalingPolicies/$4" ''
    emit 'object | policy_summary + {algorithm: (if .basicAlgorithm.yarnConfig != null then "yarn" elif .basicAlgorithm.sparkStandaloneConfig != null then "spark_standalone" else "other" end),
      scale_up_factor: (.basicAlgorithm.yarnConfig.scaleUpFactor | fraction), scale_down_factor: (.basicAlgorithm.yarnConfig.scaleDownFactor | fraction),
      scale_up_min_fraction: (.basicAlgorithm.yarnConfig.scaleUpMinWorkerFraction | fraction), scale_down_min_fraction: (.basicAlgorithm.yarnConfig.scaleDownMinWorkerFraction | fraction),
      graceful_decommission: (.basicAlgorithm.yarnConfig.gracefulDecommissionTimeout | text(32))}'
    ;;
  cluster_start|cluster_stop)
    verb=${mode#cluster_}
    body=$(jq -nc --arg uuid "$5" '{clusterUuid: $uuid}')
    request POST "clusters/$4:$verb" "$body"
    emit 'operation_summary'
    ;;
  cluster_resize_workers|cluster_resize_secondary_workers)
    if [[ $mode == cluster_resize_workers ]]; then field=workerConfig mask=config.worker_config.num_instances
    else field=secondaryWorkerConfig mask=config.secondary_worker_config.num_instances; fi
    body=$(jq -nc --arg field "$field" --argjson count "$5" '{config: {($field): {numInstances: $count}}}')
    request PATCH "clusters/$4" "$body" "updateMask=$mask" "gracefulDecommissionTimeout=${6}s"
    emit 'operation_summary'
    ;;
  cluster_delete)
    request DELETE "clusters/$4" '' "clusterUuid=$5"
    emit 'operation_summary'
    ;;
  job_cancel)
    request POST "jobs/$4:cancel" '{}'
    emit 'job_summary'
    ;;
  job_delete)
    request DELETE "jobs/$4" ''
    # Delete returns the empty object, not an operation or job. Only a
    # successful HTTP response followed by its expected shape is a receipt.
    emit 'object | if length == 0 then {id: $id, deleted: true} else error("expected an empty Dataproc deletion response") end' --arg id "$4"
    ;;
  *) printf '%s\n' 'Unsupported Dataproc action.' >&2; exit 2 ;;
esac

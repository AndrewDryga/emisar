#!/bin/bash
# Fixed Apache Airflow 2 (/api/v1) and 3 (/api/v2) REST API operations.
# The caller selects one packaged subcommand and supplies typed values; it never
# supplies shell code, a URL host, a request path, or a JSON body.
#
# Credentials never reach argv: the bearer token is streamed to curl as a header
# document on stdin (-H @-), and the username/password used to mint one are read
# from the environment by jq (env.X), so neither appears in a `ps` listing or in
# the recorded executed_command.
set -euo pipefail

readonly base="${AIRFLOW_URL:-http://127.0.0.1:8080}"
readonly api_version="${AIRFLOW_API_VERSION:-v2}"
readonly api="$base/api/$api_version"
readonly connect_timeout=10
readonly max_time=45
readonly max_response_bytes=33554432

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# The base URL is host-administrator state, not a caller argument, but curl
# would still expand a brace or bracket in it into one transfer per alternative
# and would follow a non-HTTP scheme. --globoff and --proto below are the
# enforcement; this is the readable error for an obvious typo.
validate_base() {
  case "$base" in
    http://*|https://*) ;;
    *) fail "AIRFLOW_URL must start with http:// or https://" ;;
  esac
  # Braces only. Brackets are how IPv6 spells a literal host, and rejecting
  # them disabled every action in this pack on an IPv6-only or ::-bound
  # deployment (AIRFLOW_URL=http://[::1]:8080). --globoff already stops curl
  # expanding a bracket range, which is exactly why the shape check must not
  # ban the character to get that protection.
  case "$base" in
    *['{}']*) fail "AIRFLOW_URL must not contain braces" ;;
  esac
}

# Resolved once per run. AIRFLOW_API_TOKEN wins when set; otherwise a JWT is
# minted from AIRFLOW_USERNAME/AIRFLOW_PASSWORD through the auth manager's
# POST /auth/token, which both the simple and FAB auth managers expose. With
# neither set the request goes out unauthenticated, which is all /monitor/health
# and /version need.
token=""
token_resolved=""

# Shared by token minting and API reads. Stdin remains the caller's credential
# document; only the response goes through the bounded private file.
bounded_transfer() (
  umask 077
  response_dir=$(mktemp -d "${TMPDIR:-/tmp}/emisar-airflow.XXXXXXXX") || exit 1
  trap 'rm -f -- "$response_dir/body"; rmdir -- "$response_dir"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if "$@" | head -c "$((max_response_bytes + 1))" >"$response_dir/body"; then
    statuses=("${PIPESTATUS[@]}")
  else
    statuses=("${PIPESTATUS[@]}")
  fi
  bytes=$(wc -c <"$response_dir/body")
  ((bytes <= max_response_bytes && statuses[0] != 63)) || fail "Airflow API response exceeded 32 MiB"
  ((statuses[1] == 0)) || fail "Could not read Airflow API response"
  ((statuses[0] == 0)) || exit "${statuses[0]}"
  cat "$response_dir/body"
)

resolve_token() {
  [[ -z $token_resolved ]] || return 0
  token_resolved=yes
  if [[ $api_version == v1 ]]; then
    [[ -z ${AIRFLOW_API_TOKEN:-} ]] || fail "AIRFLOW_API_TOKEN requires AIRFLOW_API_VERSION=v2; Airflow 2 uses AIRFLOW_USERNAME and AIRFLOW_PASSWORD with basic_auth"
    return 0
  fi
  if [[ -n ${AIRFLOW_API_TOKEN:-} ]]; then
    token=$AIRFLOW_API_TOKEN
    return 0
  fi
  [[ -n ${AIRFLOW_USERNAME:-} && -n ${AIRFLOW_PASSWORD:-} ]] || return 0
  local response
  response=$(jq -nc '{username: env.AIRFLOW_USERNAME, password: env.AIRFLOW_PASSWORD}' |
    bounded_transfer curl -q --globoff --proto '=http,https' --max-filesize "$max_response_bytes" -fsS -X POST \
      -H 'Content-Type: application/json' --data @- \
      --connect-timeout "$connect_timeout" --max-time "$max_time" \
      "$base/auth/token") ||
    fail "minting an Airflow API token from $base/auth/token failed"
  token=$(printf '%s' "$response" | jq -r '.access_token // empty')
  [[ -n $token ]] || fail "$base/auth/token returned no access_token"
}

auth_header() {
  if [[ $api_version == v1 && -n ${AIRFLOW_USERNAME:-} && -n ${AIRFLOW_PASSWORD:-} ]]; then
    jq -nr '"Authorization: Basic " + ((env.AIRFLOW_USERNAME + ":" + env.AIRFLOW_PASSWORD) | @base64)'
    return 0
  fi
  [[ -z $token ]] || printf 'Authorization: Bearer %s\n' "$token"
  return 0
}

# One request. -f makes any 4xx/5xx a failed action rather than an empty
# success, and --globoff keeps a brace in the assembled URL literal.
request() {
  local method=$1 url=$2 status=0 response
  shift 2
  response=$(auth_header | bounded_transfer curl -q --globoff --proto '=http,https' --max-filesize "$max_response_bytes" -fsS -H @- \
    -X "$method" --connect-timeout "$connect_timeout" --max-time "$max_time" \
    "$@" "$url") || status=$?
  ((status == 0)) || fail "Airflow API request failed with transfer status $status: $method ${url#"$base"}"
  printf '%s' "$response"
}

api_get() {
  resolve_token
  request GET "$@" -G
}

api_json() {
  local method=$1 path=$2 body=$3
  shift 3
  resolve_token
  request "$method" "$api$path" -H 'Content-Type: application/json' --data "$body" "$@"
}

# Query builder. Each pair is appended only when its value is non-empty, so an
# omitted optional argument is absent from the query rather than sent empty —
# an empty value on an enum-typed parameter is a 422 from FastAPI.
query=()

reset_query() { query=(); }

add_param() {
  [[ -n $2 ]] || return 0
  query+=(--data-urlencode "$1=$2")
}

# Repeatable list parameter: "a,b" becomes two occurrences of the parameter.
# read -ra rather than word splitting, so a value can never be glob-expanded
# against the runner's filesystem on its way into the query.
add_list_param() {
  local name=$1 value=$2 item items=()
  [[ -n $value ]] || return 0
  IFS=, read -ra items <<<"$value"
  for item in "${items[@]}"; do
    [[ -n $item ]] || continue
    query+=(--data-urlencode "$name=$item")
  done
}

v2_only() { [[ $api_version == v2 ]] || fail "$1 requires Airflow 3 (AIRFLOW_API_VERSION=v2)"; }

v2_filter() {
  [[ $api_version == v2 || -z $2 ]] || fail "$1 is not supported by Airflow 2 (AIRFLOW_API_VERSION=v1); omit this filter"
}

# ---------------------------------------------------------------- reads

health() {
  if [[ $api_version == v1 ]]; then api_get "$api/health";
  else request GET "$api/monitor/health"; fi
}

version() {
  if [[ $api_version == v1 ]]; then api_get "$api/version";
  else request GET "$api/version"; fi
}

jobs() {
  v2_only airflow.jobs
  reset_query
  add_param job_type "$1"
  add_param is_alive "$2"
  add_param hostname "$3"
  add_param limit "$4"
  add_param order_by "$5"
  api_get "$api/jobs" "${query[@]}"
}

dags() {
  reset_query
  add_param dag_id_pattern "$1"
  add_list_param tags "$2"
  add_param paused "$3"
  v2_filter last_dag_run_state "$4"
  add_param last_dag_run_state "$4"
  if [[ $api_version == v1 ]]; then add_param only_active "$5";
  else add_param exclude_stale "$5"; fi
  add_param limit "$6"
  add_param offset "$7"
  add_param order_by "$8"
  api_get "$api/dags" "${query[@]}"
}

dag() { api_get "$api/dags/$1"; }

dag_details() { api_get "$api/dags/$1/details"; }

dag_stats() {
  reset_query
  if [[ $api_version == v1 ]]; then
    [[ -n $1 ]] || fail "Airflow 2 dag_stats requires explicit dag_ids"
    add_param dag_ids "$1"
  else add_list_param dag_ids "$1"; fi
  api_get "$api/dagStats" "${query[@]}"
}

dag_tasks() { api_get "$api/dags/$1/tasks"; }

import_errors() {
  v2_filter filename_pattern "$1"
  reset_query
  add_param filename_pattern "$1"
  add_param limit "$2"
  add_param order_by "$3"
  api_get "$api/importErrors" "${query[@]}"
}

dag_warnings() {
  reset_query
  add_param dag_id "$1"
  add_param limit "$2"
  api_get "$api/dagWarnings" "${query[@]}"
}

pools() {
  v2_filter pool_name_pattern "$1"
  reset_query
  add_param pool_name_pattern "$1"
  add_param limit "$2"
  api_get "$api/pools" "${query[@]}"
}

providers() {
  if [[ $api_version == v1 ]]; then
    api_get "$api/providers" | jq -ce --argjson limit "$1" '{providers: .providers[:$limit]}'
    return
  fi
  reset_query
  add_param limit "$1"
  api_get "$api/providers" "${query[@]}"
}

# Connection secrets stay on the host: password is masked by the API, but extra
# routinely carries service-account JSON, tokens, and TLS keys that no
# redaction pattern can be relied on to catch. Only the routing metadata an
# operator needs to identify a connection leaves the runner.
#
# The password flag is named has_auth, not has_password: the runner's default
# json-secret-field rule rewrites the value under any key in its secret
# vocabulary — "has_password" included, and since it covers non-string values
# it would report "[REDACTED]" for both true and false.
connections() {
  v2_filter connection_id_pattern "$1"
  reset_query
  add_param connection_id_pattern "$1"
  add_param limit "$2"
  api_get "$api/connections" "${query[@]}" |
    jq -ce --arg version "$api_version" '{
      total_entries,
      connections: [.connections[]? | {
        connection_id, conn_type, description, host, port, schema, login,
        has_auth: (if $version == "v1" then null else ((.password // "") != "") end),
        has_extra: (if $version == "v1" then null else ((.extra // "") != "") end)
      }]
    }'
}

# Variable VALUES are arbitrary operator-authored strings — API keys and DSNs
# live there routinely — so this lists what exists and never what it holds.
variables() {
  v2_filter variable_key_pattern "$1"
  reset_query
  add_param variable_key_pattern "$1"
  add_param limit "$2"
  api_get "$api/variables" "${query[@]}" |
    jq -ce '{
      total_entries,
      variables: [.variables[]? | {
        key, description, is_encrypted,
        value_bytes: ((.value // "") | length)
      }]
    }'
}

event_logs() {
  reset_query
  add_param dag_id "$1"
  add_param task_id "$2"
  add_param event "$3"
  add_param after "$4"
  add_param limit "$5"
  add_param order_by "$6"
  api_get "$api/eventLogs" "${query[@]}"
}

assets() {
  v2_only airflow.assets
  reset_query
  add_param name_pattern "$1"
  add_list_param dag_ids "$2"
  add_param only_active "$3"
  add_param limit "$4"
  api_get "$api/assets" "${query[@]}"
}

asset_events() {
  v2_only airflow.asset_events
  reset_query
  add_param asset_id "$1"
  add_param source_dag_id "$2"
  add_param limit "$3"
  add_param order_by "$4"
  api_get "$api/assets/events" "${query[@]}"
}

dag_runs() {
  v2_filter run_type "$3"
  reset_query
  add_param state "$2"
  add_param run_type "$3"
  add_param start_date_gte "$4"
  add_param limit "$5"
  local order=$6
  if [[ $api_version == v1 ]]; then
    case "$order" in run_after) order=execution_date ;; -run_after) order=-execution_date ;; esac
  fi
  add_param order_by "$order"
  api_get "$api/dags/$1/dagRuns" "${query[@]}"
}

dag_run() { api_get "$api/dags/$1/dagRuns/$2"; }

task_instances() {
  v2_filter order_by "$7"
  local order=$7
  [[ $api_version != v2 || -n $order ]] || order=-start_date
  if [[ $api_version == v1 && -n $3 ]]; then
    api_json POST /dags/~/dagRuns/~/taskInstances/list "$(jq -nc \
      --arg dag "$1" --arg run "$2" --arg task "$3" --arg state "$4" --arg pool "$5" --argjson limit "$6" '
      {page_limit:$limit, task_ids:[$task]}
      + (if $dag == "~" then {} else {dag_ids:[$dag]} end)
      + (if $run == "~" then {} else {dag_run_ids:[$run]} end)
      + (if $state == "" then {} else {state:[$state]} end)
      + (if $pool == "" then {} else {pool:[$pool]} end)')"
    return
  fi
  reset_query
  add_param task_id "$3"
  add_param state "$4"
  add_param pool "$5"
  add_param limit "$6"
  add_param order_by "$order"
  api_get "$api/dags/$1/dagRuns/$2/taskInstances" "${query[@]}"
}

task_instance() {
  local path="$api/dags/$1/dagRuns/$2/taskInstances/$3"
  [[ $4 == "-1" ]] || path="$path/$4"
  api_get "$path"
}

# Airflow returns a task log as structured messages, one object per line. The
# reader — operator or agent — wants the log, so each message is flattened back
# to "<timestamp> <level> <message>" and the per-line logger, filename, and
# lineno metadata is dropped. The exception that failed the task rides in
# error_detail rather than the message, so it is rendered as a traceback; that
# is the whole reason to read a failed task's log. Older attempts can carry
# plain strings instead of objects, which pass through unchanged.
task_log() {
  reset_query
  add_param map_index "$5"
  add_param full_content "$6"
  resolve_token
  request GET "$api/dags/$1/dagRuns/$2/taskInstances/$3/logs/$4" \
    -G -H 'Accept: application/json' "${query[@]}" |
    jq -r '
      def traceback:
        [ (.error_detail // [])[]
          | "\n  " + (.exc_type // "Error") + ": " + (.exc_value // "")
            + ([ (.frames // [])[-20:][]
                 | "\n    at " + (.filename // "") + ":"
                   + ((.lineno // 0) | tostring) + " in " + (.name // "") ]
               | join(""))
        ] | join("");
      if (.content | type) == "string" then .content else .content[]? end
      | if type == "string" then .
        else ([(.timestamp // empty), (.level // empty), .event] | join(" ")) + traceback
        end
    '
}

backfills() {
  v2_only airflow.backfills
  reset_query
  add_param dag_id "$1"
  add_param limit "$2"
  add_param order_by "$3"
  api_get "$api/backfills" "${query[@]}"
}

# ------------------------------------------------------------ mutations

set_paused() {
  api_json PATCH "/dags/$1?update_mask=is_paused" \
    "$(jq -nc --argjson paused "$2" '{is_paused: $paused}')"
}

# Every free-text and JSON value is built by jq from the environment, so a
# quote or a brace in a note or a conf document cannot break out of the body.
trigger() {
  local body
  body=$(jq -nc '
    {logical_date: (if env.AF_LOGICAL_DATE == "" then null else env.AF_LOGICAL_DATE end)}
    + (if env.AF_DAG_RUN_ID == "" then {} else {dag_run_id: env.AF_DAG_RUN_ID} end)
    + (if env.AF_NOTE == "" then {} else {note: env.AF_NOTE} end)
    + (if env.AF_CONF == "" then {} else {conf: (env.AF_CONF | fromjson)} end)
  ') || fail "conf must be a JSON object"
  if [[ $api_version == v1 ]]; then
    body=$(printf '%s' "$body" | jq -c 'if .logical_date == null then del(.logical_date) else . end')
  fi
  api_json POST "/dags/$1/dagRuns" "$body"
}

set_dag_run_state() {
  local path="/dags/$1/dagRuns/$2"
  [[ $api_version == v1 ]] || path="$path?update_mask=state"
  api_json PATCH "$path" \
    "$(jq -nc --arg state "$3" '{state: $state}')"
}

clear_dag_run() {
  if [[ $api_version == v1 ]]; then
    clear_task_instances "$1" "$3" "$2" "" "$4" false
    return
  fi
  api_json POST "/dags/$1/dagRuns/$2/clear" \
    "$(jq -nc --argjson dry "$3" --argjson only_failed "$4" \
      '{dry_run: $dry, only_failed: $only_failed}')"
}

clear_task_instances() {
  local body
  body=$(jq -nc \
    --argjson dry "$2" \
    --arg dag_run_id "$3" \
    --arg task_ids "$4" \
    --argjson only_failed "$5" \
    --argjson include_downstream "$6" '
    {dry_run: $dry, only_failed: $only_failed, include_downstream: $include_downstream,
     reset_dag_runs: true}
    + (if $dag_run_id == "" then {} else {dag_run_id: $dag_run_id} end)
    + (if $task_ids == "" then {}
       else {task_ids: ($task_ids | split(",") | map(select(length > 0)))} end)
  ')
  api_json POST "/dags/$1/clearTaskInstances" "$body"
}

set_task_instance_state() {
  local path="/dags/$1/dagRuns/$2/taskInstances/$3"
  if [[ $api_version == v1 ]]; then
    if [[ $6 == true ]]; then
      [[ $4 == -1 ]] || fail "Airflow 2 cannot update mapped task instances with include_downstream=true"
      api_json POST "/dags/$1/updateTaskInstancesState" "$(jq -nc --arg run "$2" --arg task "$3" --arg state "$5" \
        '{dag_run_id:$run, task_id:$task, new_state:$state, dry_run:false, include_upstream:false, include_downstream:true, include_future:false, include_past:false}')"
    else
      [[ $4 == -1 ]] || path="$path/$4"
      api_json PATCH "$path" "$(jq -nc --arg state "$5" '{new_state:$state, dry_run:false}')" >/dev/null
      task_instance "$1" "$2" "$3" "$4"
    fi
    return
  fi
  [[ $4 == "-1" ]] || path="$path?map_index=$4"
  api_json PATCH "$path" \
    "$(jq -nc --arg state "$5" --argjson downstream "$6" \
      '{new_state: $state, include_downstream: $downstream}')"
}

# 204 No Content: report the deletion the caller asked for rather than an
# empty body a JSON parser would reject.
delete_dag_run() {
  resolve_token
  request DELETE "$api/dags/$1/dagRuns/$2" >/dev/null
  jq -nc --arg dag_id "$1" --arg dag_run_id "$2" \
    '{deleted: true, dag_id: $dag_id, dag_run_id: $dag_run_id}'
}

# The pool PATCH body is validated in full even though update_mask limits what
# is applied, so the current pool is read first and only its slot count is
# replaced. That also keeps the action from depending on defaults for fields it
# was never asked to change.
set_pool_slots() {
  if [[ $api_version == v1 ]]; then
    api_json PATCH "/pools/$1?update_mask=slots" "$(jq -nc --argjson slots "$2" '{slots:$slots}')"
    return
  fi
  resolve_token
  local body
  body=$(request GET "$api/pools/$1" |
    jq -c --argjson slots "$2" \
      '{pool: .name, slots: $slots, include_deferred: .include_deferred}')
  api_json PATCH "/pools/$1?update_mask=slots" "$body"
}

create_backfill() {
  v2_only airflow.backfill_create
  api_json POST /backfills "$(jq -nc \
    --arg dag_id "$1" \
    --arg from_date "$2" \
    --arg to_date "$3" \
    --arg reprocess "$4" \
    --argjson max_active_runs "$5" \
    --argjson run_backwards "$6" '
    {dag_id: $dag_id, from_date: $from_date, to_date: $to_date,
     reprocess_behavior: $reprocess, max_active_runs: $max_active_runs,
     run_backwards: $run_backwards}
  ')"
}

cancel_backfill() {
  v2_only airflow.backfill_cancel
  resolve_token
  request PUT "$api/backfills/$1/cancel"
}

pause_backfill() {
  v2_only airflow.backfill_pause
  resolve_token
  request PUT "$api/backfills/$1/pause"
}

validate_base
case "$api_version" in
  v1|v2) ;;
  *) fail "AIRFLOW_API_VERSION must be v1 (Airflow 2) or v2 (Airflow 3)" ;;
esac
if [[ $api_version == v1 || -z ${AIRFLOW_API_TOKEN:-} ]] &&
   [[ -n ${AIRFLOW_USERNAME:-} && -z ${AIRFLOW_PASSWORD:-} || -z ${AIRFLOW_USERNAME:-} && -n ${AIRFLOW_PASSWORD:-} ]]; then
  fail "AIRFLOW_USERNAME and AIRFLOW_PASSWORD must be set together"
fi

command=${1:-}
shift || true
case "$command" in
  health) health ;;
  version) version ;;
  jobs) jobs "$@" ;;
  dags) dags "$@" ;;
  dag) dag "$@" ;;
  dag-details) dag_details "$@" ;;
  dag-stats) dag_stats "$@" ;;
  dag-tasks) dag_tasks "$@" ;;
  import-errors) import_errors "$@" ;;
  dag-warnings) dag_warnings "$@" ;;
  pools) pools "$@" ;;
  providers) providers "$@" ;;
  connections) connections "$@" ;;
  variables) variables "$@" ;;
  event-logs) event_logs "$@" ;;
  assets) assets "$@" ;;
  asset-events) asset_events "$@" ;;
  dag-runs) dag_runs "$@" ;;
  dag-run) dag_run "$@" ;;
  task-instances) task_instances "$@" ;;
  task-instance) task_instance "$@" ;;
  task-log) task_log "$@" ;;
  backfills) backfills "$@" ;;
  set-paused) set_paused "$@" ;;
  trigger) trigger "$@" ;;
  set-dag-run-state) set_dag_run_state "$@" ;;
  clear-dag-run) clear_dag_run "$@" ;;
  clear-task-instances) clear_task_instances "$@" ;;
  set-task-instance-state) set_task_instance_state "$@" ;;
  delete-dag-run) delete_dag_run "$@" ;;
  set-pool-slots) set_pool_slots "$@" ;;
  create-backfill) create_backfill "$@" ;;
  cancel-backfill) cancel_backfill "$@" ;;
  pause-backfill) pause_backfill "$@" ;;
  *) fail "unknown airflow operation" ;;
esac

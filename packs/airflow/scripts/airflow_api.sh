#!/bin/bash
# Fixed Apache Airflow 3 REST API (/api/v2) operations for the "airflow" pack.
# The caller selects one packaged subcommand and supplies typed values; it never
# supplies shell code, a URL host, a request path, or a JSON body.
#
# Credentials never reach argv: the bearer token is streamed to curl as a header
# document on stdin (-H @-), and the username/password used to mint one are read
# from the environment by jq (env.X), so neither appears in a `ps` listing or in
# the recorded executed_command.
set -euo pipefail

readonly base="${AIRFLOW_URL:-http://127.0.0.1:8080}"
readonly api="$base/api/v2"
readonly connect_timeout=10
readonly max_time=45

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
  case "$base" in
    *['{}[]']*) fail "AIRFLOW_URL must not contain braces or brackets" ;;
  esac
}

# Resolved once per run. AIRFLOW_API_TOKEN wins when set; otherwise a JWT is
# minted from AIRFLOW_USERNAME/AIRFLOW_PASSWORD through the auth manager's
# POST /auth/token, which both the simple and FAB auth managers expose. With
# neither set the request goes out unauthenticated, which is all /monitor/health
# and /version need.
token=""
token_resolved=""

resolve_token() {
  [[ -z $token_resolved ]] || return 0
  token_resolved=yes
  if [[ -n ${AIRFLOW_API_TOKEN:-} ]]; then
    token=$AIRFLOW_API_TOKEN
    return 0
  fi
  [[ -n ${AIRFLOW_USERNAME:-} && -n ${AIRFLOW_PASSWORD:-} ]] || return 0
  local response
  response=$(jq -nc '{username: env.AIRFLOW_USERNAME, password: env.AIRFLOW_PASSWORD}' |
    curl --globoff --proto '=http,https' -fsS -X POST \
      -H 'Content-Type: application/json' --data @- \
      --connect-timeout "$connect_timeout" --max-time "$max_time" \
      "$base/auth/token") ||
    fail "minting an Airflow API token from $base/auth/token failed"
  token=$(printf '%s' "$response" | jq -r '.access_token // empty')
  [[ -n $token ]] || fail "$base/auth/token returned no access_token"
}

auth_header() {
  [[ -z $token ]] || printf 'Authorization: Bearer %s\n' "$token"
  return 0
}

# One request. -f makes any 4xx/5xx a failed action rather than an empty
# success, and --globoff keeps a brace in the assembled URL literal.
request() {
  local method=$1 url=$2 status=0 response
  shift 2
  response=$(auth_header | curl --globoff --proto '=http,https' -fsS -H @- \
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

# ---------------------------------------------------------------- reads

health() { request GET "$api/monitor/health"; }

version() { request GET "$api/version"; }

jobs() {
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
  add_param last_dag_run_state "$4"
  add_param exclude_stale "$5"
  add_param limit "$6"
  add_param offset "$7"
  add_param order_by "$8"
  api_get "$api/dags" "${query[@]}"
}

dag() { api_get "$api/dags/$1"; }

dag_details() { api_get "$api/dags/$1/details"; }

dag_stats() {
  reset_query
  add_list_param dag_ids "$1"
  api_get "$api/dagStats" "${query[@]}"
}

dag_tasks() { api_get "$api/dags/$1/tasks"; }

import_errors() {
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
  reset_query
  add_param pool_name_pattern "$1"
  add_param limit "$2"
  api_get "$api/pools" "${query[@]}"
}

providers() {
  reset_query
  add_param limit "$1"
  api_get "$api/providers" "${query[@]}"
}

# Connection secrets stay on the host: password is masked by the API, but extra
# routinely carries service-account JSON, tokens, and TLS keys that no
# redaction pattern can be relied on to catch. Only the routing metadata an
# operator needs to identify a connection leaves the runner.
connections() {
  reset_query
  add_param connection_id_pattern "$1"
  add_param limit "$2"
  api_get "$api/connections" "${query[@]}" |
    jq -ce '{
      total_entries,
      connections: [.connections[]? | {
        connection_id, conn_type, description, host, port, schema, login,
        has_password: ((.password // "") != ""),
        has_extra: ((.extra // "") != "")
      }]
    }'
}

# Variable VALUES are arbitrary operator-authored strings — API keys and DSNs
# live there routinely — so this lists what exists and never what it holds.
variables() {
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
  reset_query
  add_param name_pattern "$1"
  add_list_param dag_ids "$2"
  add_param only_active "$3"
  add_param limit "$4"
  api_get "$api/assets" "${query[@]}"
}

asset_events() {
  reset_query
  add_param asset_id "$1"
  add_param source_dag_id "$2"
  add_param limit "$3"
  add_param order_by "$4"
  api_get "$api/assets/events" "${query[@]}"
}

dag_runs() {
  reset_query
  add_param state "$2"
  add_param run_type "$3"
  add_param start_date_gte "$4"
  add_param limit "$5"
  add_param order_by "$6"
  api_get "$api/dags/$1/dagRuns" "${query[@]}"
}

dag_run() { api_get "$api/dags/$1/dagRuns/$2"; }

task_instances() {
  reset_query
  add_param task_id "$3"
  add_param state "$4"
  add_param pool "$5"
  add_param limit "$6"
  add_param order_by "$7"
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
      .content[]?
      | if type == "string" then .
        else ([(.timestamp // empty), (.level // empty), .event] | join(" ")) + traceback
        end
    '
}

backfills() {
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
  api_json POST "/dags/$1/dagRuns" "$body"
}

set_dag_run_state() {
  api_json PATCH "/dags/$1/dagRuns/$2?update_mask=state" \
    "$(jq -nc --arg state "$3" '{state: $state}')"
}

clear_dag_run() {
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
  resolve_token
  local body
  body=$(request GET "$api/pools/$1" |
    jq -c --argjson slots "$2" \
      '{pool: .name, slots: $slots, include_deferred: .include_deferred}')
  api_json PATCH "/pools/$1?update_mask=slots" "$body"
}

create_backfill() {
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
  resolve_token
  request PUT "$api/backfills/$1/cancel"
}

pause_backfill() {
  resolve_token
  request PUT "$api/backfills/$1/pause"
}

validate_base

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

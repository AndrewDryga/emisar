#!/bin/bash
# Fixed Apache Spark operations for the "spark" pack, over the three HTTP
# surfaces a Spark deployment exposes: the monitoring REST API (/api/v1, served
# identically by a live driver UI and by the history server), the standalone
# master UI, and the standalone REST submission server.
#
# The caller selects one packaged subcommand and supplies typed values; it never
# supplies shell code, a URL host, or a request path. An optional bearer token
# for a proxy-authenticated UI is streamed to curl on stdin, never argv.
set -euo pipefail

readonly history_base="${SPARK_HISTORY_URL:-http://127.0.0.1:18080}"
readonly driver_base="${SPARK_UI_URL:-http://127.0.0.1:4040}"
readonly master_base="${SPARK_MASTER_URL:-http://127.0.0.1:8080}"
readonly rest_base="${SPARK_REST_URL:-http://127.0.0.1:6066}"
readonly connect_timeout=10
readonly max_time=45

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

# The base URLs these are assembled from are host-administrator state, not
# caller arguments, but curl would still expand a brace or bracket in one into a
# transfer per alternative and would follow a non-HTTP scheme. --globoff and
# --proto below are the enforcement; this is the readable error for a typo.
validate_url() {
  local url=$1
  case "$url" in
    http://*|https://*) ;;
    *) fail "Spark URL must start with http:// or https://: $url" ;;
  esac
  case "$url" in
    *['{}[]']*) fail "Spark URL must not contain braces or brackets: $url" ;;
  esac
}

# history and driver speak the same /api/v1 contract; which one to ask is the
# caller's choice because only a live driver knows about a running application
# and only the history server keeps a finished one.
api_base() {
  case "$1" in
    history) printf '%s' "$history_base" ;;
    driver) printf '%s' "$driver_base" ;;
    *) fail "source must be history or driver" ;;
  esac
}

auth_header() {
  [[ -z ${SPARK_API_TOKEN:-} ]] || printf 'Authorization: Bearer %s\n' "$SPARK_API_TOKEN"
  return 0
}

# One request. -f makes any 4xx/5xx a failed action rather than an empty
# success, and --globoff keeps a brace in the assembled URL literal.
request() {
  local method=$1 url=$2 status=0 response
  shift 2
  validate_url "$url"
  response=$(auth_header | curl --globoff --proto '=http,https' -fsS -H @- \
    -X "$method" --connect-timeout "$connect_timeout" --max-time "$max_time" \
    "$@" "$url") || status=$?
  ((status == 0)) || fail "Spark request failed with transfer status $status: $method $url"
  printf '%s' "$response"
}

api_get() { request GET "$@" -G; }

query=()

reset_query() { query=(); }

add_param() {
  [[ -n $2 ]] || return 0
  query+=(--data-urlencode "$1=$2")
}

# A driver UI serves exactly one application, so the kill endpoints — which are
# not application-scoped — resolve it rather than making the caller supply an
# id they cannot see from the UI.
driver_app_id() {
  local id
  id=$(api_get "$driver_base/api/v1/applications" | jq -r '.[0].id // empty')
  [[ -n $id ]] || fail "no application is running on the driver UI at $driver_base"
  printf '%s' "$id"
}

# ---------------------------------------------------------------- reads

version() { api_get "$(api_base "$1")/api/v1/version"; }

applications() {
  local base
  base=$(api_base "$1")
  reset_query
  add_param status "$2"
  add_param limit "$3"
  add_param minDate "$4"
  api_get "$base/api/v1/applications" "${query[@]}"
}

application() { api_get "$(api_base "$1")/api/v1/applications/$2"; }

jobs() {
  local base
  base=$(api_base "$1")
  reset_query
  add_param status "$3"
  api_get "$base/api/v1/applications/$2/jobs" "${query[@]}"
}

job() { api_get "$(api_base "$1")/api/v1/applications/$2/jobs/$3"; }

stages() {
  local base
  base=$(api_base "$1")
  reset_query
  add_param status "$3"
  add_param details "$4"
  api_get "$base/api/v1/applications/$2/stages" "${query[@]}"
}

stage() {
  local base
  base=$(api_base "$1")
  reset_query
  add_param details "$4"
  add_param withSummaries "$5"
  api_get "$base/api/v1/applications/$2/stages/$3" "${query[@]}"
}

stage_task_summary() {
  local base
  base=$(api_base "$1")
  reset_query
  add_param quantiles "$5"
  api_get "$base/api/v1/applications/$2/stages/$3/$4/taskSummary" "${query[@]}"
}

stage_tasks() {
  local base
  base=$(api_base "$1")
  reset_query
  add_param offset "$5"
  add_param length "$6"
  add_param status "$7"
  add_param sortBy "$8"
  api_get "$base/api/v1/applications/$2/stages/$3/$4/taskList" "${query[@]}"
}

executors() {
  local base path=executors
  base=$(api_base "$1")
  [[ $3 != "true" ]] || path=allexecutors
  api_get "$base/api/v1/applications/$2/$path"
}

executor_threads() {
  api_get "$driver_base/api/v1/applications/$1/executors/$2/threads"
}

# The environment endpoint returns every Spark and system property, which is
# where object-store keys and keystore passwords live. Spark's own
# spark.redaction.regex masks the properties it recognizes; this drops the JVM
# system properties and the classpath as well, leaving the Spark configuration
# and runtime an operator actually reads. It is still a configuration dump —
# the action that calls it says so and is priced accordingly.
environment() {
  api_get "$(api_base "$1")/api/v1/applications/$2/environment" |
    jq -ce '{runtime, sparkProperties, resourceProfiles}'
}

sql_list() {
  local base
  base=$(api_base "$1")
  reset_query
  add_param offset "$3"
  add_param length "$4"
  add_param planDescription "$5"
  add_param details "false"
  api_get "$base/api/v1/applications/$2/sql" "${query[@]}"
}

sql_execution() {
  local base
  base=$(api_base "$1")
  reset_query
  add_param planDescription "$4"
  add_param details "true"
  api_get "$base/api/v1/applications/$2/sql/$3" "${query[@]}"
}

storage_rdds() { api_get "$(api_base "$1")/api/v1/applications/$2/storage/rdd"; }

# The standalone master's cluster state: alive and dead workers with their core
# and memory totals, running and completed applications, and drivers.
master_state() { api_get "$master_base/json/"; }

submission_status() { api_get "$rest_base/v1/submissions/status/$1"; }

# ------------------------------------------------------------ mutations

# The driver UI's kill endpoints answer with a redirect and an empty body
# whether or not anything was killed, so the outcome is read back from the
# monitoring API rather than assumed.
job_kill() {
  local app_id
  app_id=$(driver_app_id)
  reset_query
  add_param id "$1"
  request POST "$driver_base/jobs/job/kill/" -G "${query[@]}" >/dev/null
  api_get "$driver_base/api/v1/applications/$app_id/jobs/$1" |
    jq -ce '{jobId, name, status, numActiveTasks, numFailedTasks, numKilledTasks}'
}

stage_kill() {
  local app_id
  app_id=$(driver_app_id)
  reset_query
  add_param id "$1"
  request POST "$driver_base/stages/stage/kill/" -G "${query[@]}" >/dev/null
  api_get "$driver_base/api/v1/applications/$app_id/stages/$1" |
    jq -ce '[.[] | {stageId, attemptId, status, numActiveTasks, numFailedTasks, numKilledTasks}]'
}

# The master acknowledges a kill as soon as it has asked the worker, so reading
# the state back a millisecond later reports the entry still active. This waits
# for it to leave the active list, bounded — a kill that never lands is
# reported as still active rather than waited on forever.
await_master_removal() {
  local field=$1 id=$2 attempt state
  for attempt in $(seq 1 20); do
    state=$(master_state)
    if [[ $(printf '%s' "$state" |
      jq -r --arg field "$field" --arg id "$id" \
        '[(.[$field] // [])[] | select(.id == $id)] | length') == "0" ]]; then
      break
    fi
    sleep 1
  done
  printf '%s' "$state"
}

master_app_kill() {
  reset_query
  add_param id "$1"
  add_param terminate true
  request POST "$master_base/app/kill/" -G "${query[@]}" >/dev/null
  await_master_removal activeapps "$1" | jq -ce --arg id "$1" '{
    app_id: $id,
    still_active: ([.activeapps[]? | select(.id == $id)] | length > 0),
    state: ([.completedapps[]? | select(.id == $id) | .state] | first)
  }'
}

master_driver_kill() {
  reset_query
  add_param id "$1"
  add_param terminate true
  request POST "$master_base/driver/kill/" -G "${query[@]}" >/dev/null
  await_master_removal activedrivers "$1" | jq -ce --arg id "$1" '{
    driver_id: $id,
    still_active: ([.activedrivers[]? | select(.id == $id)] | length > 0),
    state: ([.completeddrivers[]? | select(.id == $id) | .state] | first)
  }'
}

master_worker_decommission() {
  reset_query
  add_param host "$1"
  request POST "$master_base/workers/kill/" -G "${query[@]}" >/dev/null
  master_state | jq -ce --arg host "$1" '{
    host: $host,
    workers: [.workers[]? | select(.host == $host) | {id, host, state}]
  }'
}

submission_kill() { request POST "$rest_base/v1/submissions/kill/$1"; }

command=${1:-}
shift || true
case "$command" in
  version) version "$@" ;;
  applications) applications "$@" ;;
  application) application "$@" ;;
  jobs) jobs "$@" ;;
  job) job "$@" ;;
  stages) stages "$@" ;;
  stage) stage "$@" ;;
  stage-task-summary) stage_task_summary "$@" ;;
  stage-tasks) stage_tasks "$@" ;;
  executors) executors "$@" ;;
  executor-threads) executor_threads "$@" ;;
  environment) environment "$@" ;;
  sql-list) sql_list "$@" ;;
  sql) sql_execution "$@" ;;
  storage-rdds) storage_rdds "$@" ;;
  master-state) master_state ;;
  submission-status) submission_status "$@" ;;
  job-kill) job_kill "$@" ;;
  stage-kill) stage_kill "$@" ;;
  master-app-kill) master_app_kill "$@" ;;
  master-driver-kill) master_driver_kill "$@" ;;
  master-worker-decommission) master_worker_decommission "$@" ;;
  submission-kill) submission_kill "$@" ;;
  *) fail "unknown spark operation" ;;
esac

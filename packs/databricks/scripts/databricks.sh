#!/bin/bash
# databricks.sh — packaged with the "databricks" emisar pack. emisar loads it
# from disk when the pack is trusted, journals its SHA-256 with every run, and
# runs it via the interpreter named in each action. It is never fetched or
# assembled at request time.
#
# One authenticated exchange with a Databricks workspace REST API.
# $DATABRICKS_HOST is the workspace URL and $DATABRICKS_TOKEN is streamed as an
# Authorization header over stdin (-H @-), so the token never lands in argv, a
# `ps` listing, or the audit log.
set -euo pipefail

readonly max_response_bytes=33554432

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

api_base() {
  printf '%s/api' "${DATABRICKS_HOST%/}"
}

# curl's protocol allowlist follows the scheme the OPERATOR configured. The
# behavior fixture serves plain http on a private network, and a proxied
# workspace may too — that is their call. What the pin is actually for is
# stopping a crafted path from switching the transfer to file:// or ftp://,
# and it still does.
api_protocols() {
  case "${DATABRICKS_HOST:-}" in
  http://*) printf '%s' '=http' ;;
  *) printf '%s' '=https' ;;
  esac
}

# --fail-with-body keeps the API's error document while still exiting non-zero,
# so a rejected request reports {error_code, message} instead of failing blank.
# Plain --fail would throw the body away. Needs curl 7.76 or newer.
api_get() {
  printf 'Authorization: Bearer %s\n' "${DATABRICKS_TOKEN:-}" |
    curl -q --globoff --proto "$(api_protocols)" --fail-with-body -sS -H @- "$(api_base)$1"
}

# -G folds --data-urlencode pairs into the query string, which is the only
# safe transport for opaque continuation tokens and operator-named filters.
api_get_q() {
  local path=$1
  shift
  printf 'Authorization: Bearer %s\n' "${DATABRICKS_TOKEN:-}" |
    curl -q --globoff --proto "$(api_protocols)" --fail-with-body -sS -G -H @- \
      "$@" "$(api_base)$path"
}

api_post() {
  local path=$1
  shift
  (($# == 0)) || set -- --data "$1"
  printf 'Authorization: Bearer %s\n' "${DATABRICKS_TOKEN:-}" |
    curl -q --globoff --proto "$(api_protocols)" --fail-with-body -sS -X POST -H @- \
      -H 'Content-Type: application/json' \
      "$@" "$(api_base)$path"
}

request() {
  local response status=0
  response=$("$@") || status=$?
  if ((status != 0)); then
    printf '%s\n' "$response" >&2
    fail "Databricks rejected the request — request exit status $status"
  fi
  ((${#response} <= max_response_bytes)) || fail "API response exceeded 32 MiB"
  printf '%s' "$response"
}

# The read-statement guard for sql_query. A guardrail against accidental
# writes, not a security boundary — the warehouse enforces the token's grants.
# WITH is rejected because Spark SQL allows INSERT/UPDATE/DELETE/MERGE after
# the CTE list, so a WITH-leading statement can write; a CTE belongs in a
# subquery instead. Leading comments are rejected rather than parsed: the
# first thing in the statement must be the keyword itself.
require_read_statement() {
  local sql=$1 first rest
  while [[ "$sql" == *";" || "$sql" == *" " || "$sql" == *$'\t' || "$sql" == *$'\n' || "$sql" == *$'\r' ]]; do
    sql=${sql%?}
  done
  while [[ "$sql" == " "* || "$sql" == $'\t'* || "$sql" == $'\n'* || "$sql" == $'\r'* ]]; do
    sql=${sql#?}
  done
  [[ -n "$sql" ]] || fail "sql is empty"
  case "$sql" in
    --* | /\** | \(*)
      fail "start sql with the keyword itself — a leading comment or parenthesis is not accepted"
      ;;
  esac
  read -r first rest <<<"$sql" || true
  case "${first^^}" in
    SELECT | VALUES | SHOW | DESCRIBE | DESC | EXPLAIN) ;;
    WITH)
      fail "sql must not start with WITH — Spark SQL allows a write after the CTE list; put the WITH inside a subquery: SELECT ... FROM (WITH ... SELECT ...) q"
      ;;
    *)
      fail "sql must be a single read statement starting with SELECT, VALUES, SHOW, DESCRIBE, or EXPLAIN"
      ;;
  esac
  printf '%s' "$sql"
}

# clipped bounds every free-text field: the runner rejects a structured result
# over 8 KiB, so a page at the maximum advertised page size must fit it in the
# worst case. Control bytes collapse to one space, then the value is cut to
# $chars codepoints AND $bytes UTF-8 bytes — JSON escaping can double bytes
# (quote, backslash, U+2028/29), so the byte bound is what the page arithmetic
# in each action relies on — with an ellipsis marking the cut.
#
# controls_collapsed does that cleanup on core jq. The obvious spelling,
# gsub("[[:cntrl:]]+"; " "), needs Oniguruma, which jq's own supported
# --with-oniguruma=no build omits: there the call raises "jq was compiled
# without ONIGURUMA regex library" the first time it runs, and since every
# projection here clips a field, every one of them fails on such a host. The
# class Oniguruma matched is exactly Unicode Cc, U+0000–U+001F and
# U+007F–U+009F, so each of those codepoints becomes 0 — itself a control, so
# no ordinary character collides with the marker — a run keeps only its first,
# and the survivor becomes a space. A space already in the text is left alone.
#
# cursor_of normalizes pagination: the clusters API spells "no further
# results" as an empty-string token, the rest omit the field — both become
# null so a caller can page on a plain non-null check. The projected key is
# next_page_cursor, never *_token: the runner's json-secret-field redaction
# rewrites any string under a token-named key to [REDACTED], which would eat
# the cursor before the model ever saw it.
readonly preamble='
def controls_collapsed:
  (explode | map(if . <= 31 or (. >= 127 and . <= 159) then 0 else . end)) as $cs
  | [range($cs | length) | select(. == 0 or $cs[.] != 0 or $cs[. - 1] != 0) | $cs[.]]
  | map(if . == 0 then 32 else . end)
  | implode;

def clipped($chars; $bytes):
  (. // "" | tostring | controls_collapsed) as $clean
  | ($clean | .[:$chars] | until(utf8bytelength <= $bytes; .[:-1])) as $cut
  | if $cut == $clean then $clean else ($cut | .[:$chars - 1]) + "…" end;

def cursor_of: (.next_page_token // null) | if . == "" then null else . end;

def tail_lines($n; $chars; $bytes):
  (. // "" | tostring) as $text
  | if $text == "" then []
    else [$text | split("\n") | .[- $n:][] | clipped($chars; $bytes)]
    end;
'

# ── identity ────────────────────────────────────────────────────────────────

whoami_me() {
  local response
  response=$(request api_get "/2.0/preview/scim/v2/Me")
  printf '%s' "$response" |
    jq -ce "$preamble"'
      {
        id: (.id | clipped(48; 48)),
        user_name: (.userName | clipped(100; 160)),
        display_name: (.displayName // .userName | clipped(80; 160)),
        active: (.active == true)
      }'
}

# ── SQL statement execution ─────────────────────────────────────────────────

# The statement projection has to survive an arbitrary result shape: any
# column count, any cell size. Columns cap at 16. Rows are admitted against a
# byte budget — each clipped row costs its encoded size doubled (the runner's
# canonical re-encode can double escapes) — and everything not shown is
# counted in rows_omitted, including rows the API itself held back (row_limit
# trim or a further chunk): total_row_count is the authoritative total.
#
# A statement-level failure arrives as HTTP 200 with status.state FAILED, so
# the state gate here is the actual error handling, not decoration.
readonly statement_projection='
def statement_of:
  (.status.state // "") as $state
  | if $state == "FAILED" or $state == "CANCELED" then
      error("Databricks SQL \($state | ascii_downcase) ["
        + (.status.error.error_code // "UNKNOWN") + "]: "
        + (.status.error.message // "no message" | clipped(200; 300)))
    elif $state == "CLOSED" then
      error("the statement succeeded but its result is no longer fetchable — run it again")
    elif $state == "PENDING" or $state == "RUNNING" then
      {statement_id: .statement_id, state: $state}
    elif $state != "SUCCEEDED" then
      error("Databricks reported an unexpected statement state \($state | clipped(24; 24) | tojson)")
    else
      ([.manifest.schema.columns[]?] | sort_by(.position)) as $cols
      | [.result.data_array[]?] as $raw
      | (.manifest.total_row_count // null) as $total
      | (reduce $raw[] as $row ({kept: [], bytes: 0, open: true};
          if .open then
            ([$row[:16][] | if . == null then null else (tostring | clipped(60; 100)) end]) as $r
            | (($r | tojson | utf8bytelength) * 2 + 2) as $cost
            | if .bytes + $cost <= 5400 then {kept: (.kept + [$r]), bytes: (.bytes + $cost), open: true}
              else . + {open: false}
              end
          else .
          end)) as $admitted
      | {
          statement_id: .statement_id,
          state: $state,
          columns: [$cols[:16][] | {name: (.name | clipped(40; 40)), type: (.type_name // .type_text // "" | clipped(24; 24))}],
          columns_omitted: ([($cols | length) - 16, 0] | max),
          rows: $admitted.kept,
          rows_omitted: ((($raw | length) - ($admitted.kept | length))
            + (if $total != null and $total > ($raw | length) then $total - ($raw | length) else 0 end)),
          total_rows: $total,
          api_truncated: (.manifest.truncated == true)
        }
    end;
'

sql_query() {
  local sql=$1 warehouse_id=$2 catalog=$3 schema=$4 wait_seconds=$5 row_limit=$6 body
  sql=$(require_read_statement "$sql")
  body=$(jq -nc --arg statement "$sql" --arg warehouse_id "$warehouse_id" \
    --arg catalog "$catalog" --arg schema "$schema" \
    --argjson wait "$wait_seconds" --argjson row_limit "$row_limit" '
    {
      statement: $statement,
      warehouse_id: $warehouse_id,
      wait_timeout: "\($wait)s",
      on_wait_timeout: "CONTINUE",
      disposition: "INLINE",
      format: "JSON_ARRAY",
      row_limit: $row_limit,
      byte_limit: 262144
    }
    + (if $catalog == "" then {} else {catalog: $catalog} end)
    + (if $schema == "" then {} else {schema: $schema} end)')
  local response
  response=$(request api_post "/2.0/sql/statements" "$body")
  printf '%s' "$response" |
    jq -ce "$preamble$statement_projection"'statement_of'
}

sql_statement() {
  local response
  response=$(request api_get "/2.0/sql/statements/$1")
  printf '%s' "$response" |
    jq -ce "$preamble$statement_projection"'statement_of'
}

# Cancel is best-effort and bodyless; the re-read reports the state the
# statement actually reached — a statement that finished first stays as it
# ended, and that is the honest answer.
sql_statement_cancel() {
  local statement_id=$1
  request api_post "/2.0/sql/statements/$statement_id/cancel" >/dev/null
  local response
  response=$(request api_get "/2.0/sql/statements/$statement_id")
  printf '%s' "$response" |
    jq -ce '{statement_id: .statement_id, state: (.status.state // error("statement state missing from the response"))}'
}

# ── Unity Catalog ───────────────────────────────────────────────────────────

# max_results is always sent explicitly: the API's documented behavior when it
# is unset is to return EVERY catalog with no pagination.
catalogs_list() {
  local page_size=$1 page_token=$2
  set -- --data-urlencode "max_results=$page_size"
  [[ -z "$page_token" ]] || set -- "$@" --data-urlencode "page_token=$page_token"
  local response
  response=$(request api_get_q "/2.1/unity-catalog/catalogs" "$@")
  printf '%s' "$response" |
    jq -ce "$preamble"'
      {
        catalogs: [
          .catalogs[]?
          | {
              name: (.name | clipped(60; 100)),
              catalog_type: (.catalog_type // "" | clipped(40; 40)),
              owner: (.owner | clipped(40; 60)),
              comment: (.comment | clipped(40; 60)),
              created_at: (.created_at // null)
            }
        ],
        next_page_cursor: cursor_of
      }'
}

schemas_list() {
  local catalog=$1 page_size=$2 page_token=$3
  set -- --data-urlencode "catalog_name=$catalog" --data-urlencode "max_results=$page_size"
  [[ -z "$page_token" ]] || set -- "$@" --data-urlencode "page_token=$page_token"
  local response
  response=$(request api_get_q "/2.1/unity-catalog/schemas" "$@")
  printf '%s' "$response" |
    jq -ce "$preamble"'
      {
        schemas: [
          .schemas[]?
          | {
              name: (.name | clipped(60; 100)),
              owner: (.owner | clipped(40; 60)),
              comment: (.comment | clipped(40; 60)),
              created_at: (.created_at // null)
            }
        ],
        next_page_cursor: cursor_of
      }'
}

# omit_columns keeps a table page small; one table's full column list is
# databricks.table_get's job.
tables_list() {
  local catalog=$1 schema=$2 page_size=$3 page_token=$4
  set -- --data-urlencode "catalog_name=$catalog" --data-urlencode "schema_name=$schema" \
    --data-urlencode "max_results=$page_size" --data-urlencode "omit_columns=true"
  [[ -z "$page_token" ]] || set -- "$@" --data-urlencode "page_token=$page_token"
  local response
  response=$(request api_get_q "/2.1/unity-catalog/tables" "$@")
  printf '%s' "$response" |
    jq -ce "$preamble"'
      {
        tables: [
          .tables[]?
          | {
              name: (.name | clipped(60; 100)),
              table_type: (.table_type // "" | clipped(40; 40)),
              data_source_format: (if .data_source_format then (.data_source_format | clipped(40; 40)) else null end),
              comment: (.comment | clipped(40; 60)),
              updated_at: (.updated_at // null)
            }
        ],
        next_page_cursor: cursor_of
      }'
}

table_get() {
  local response
  response=$(request api_get "/2.1/unity-catalog/tables/$1")
  printf '%s' "$response" |
    jq -ce "$preamble"'
      ([.columns[]?] | sort_by(.position)) as $cols
      | {
          table: {
            full_name: (.full_name // .name // "" | clipped(255; 255)),
            table_type: (.table_type // "" | clipped(40; 40)),
            data_source_format: (if .data_source_format then (.data_source_format | clipped(40; 40)) else null end),
            owner: (.owner | clipped(40; 60)),
            comment: (.comment | clipped(60; 100)),
            created_at: (.created_at // null),
            updated_at: (.updated_at // null),
            view_definition: (if .view_definition then (.view_definition | clipped(1200; 1200)) else null end),
            columns: [
              $cols[:12][]
              | {
                  name: (.name | clipped(40; 60)),
                  type: (.type_text // .type_name // "" | clipped(40; 60)),
                  nullable: (.nullable != false),
                  comment: (if .comment then (.comment | clipped(24; 24)) else null end)
                }
            ],
            columns_omitted: ([($cols | length) - 12, 0] | max)
          }
        }'
}

# ── AI/BI (Lakeview) dashboards ─────────────────────────────────────────────

dashboards_list() {
  local page_size=$1 page_token=$2
  set -- --data-urlencode "page_size=$page_size"
  [[ -z "$page_token" ]] || set -- "$@" --data-urlencode "page_token=$page_token"
  local response
  response=$(request api_get_q "/2.0/lakeview/dashboards" "$@")
  printf '%s' "$response" |
    jq -ce "$preamble"'
      {
        dashboards: [
          .dashboards[]?
          | {
              dashboard_id: (.dashboard_id | clipped(40; 40)),
              display_name: (.display_name | clipped(60; 100)),
              lifecycle_state: (.lifecycle_state // "" | clipped(24; 24)),
              create_time: (.create_time // "" | clipped(40; 40)),
              warehouse_id: (if .warehouse_id then (.warehouse_id | clipped(40; 40)) else null end)
            }
        ],
        next_page_cursor: cursor_of
      }'
}

# The dashboard document arrives as one JSON string field; fromjson fails loud
# on a malformed document rather than projecting a confident empty dashboard.
# Datasets carry their SQL as queryLines on every current write; the legacy
# single-string query field is met too so an old dashboard still reads.
#
# The generic clipped would fold the query onto one line — its control
# collapse eats newlines, and a -- comment would then swallow the rest of the
# statement — so SQL keeps \n and \t and collapses only the other controls.
readonly dashboard_doc='
def dashboard_doc: (.serialized_dashboard // "{}") | fromjson;

def dataset_sql: (.queryLines // (if .query then [.query] else [] end)) | join("");

def sql_controls_collapsed:
  (explode | map(if ((. <= 31 and . != 9 and . != 10) or (. >= 127 and . <= 159)) then 0 else . end)) as $cs
  | [range($cs | length) | select(. == 0 or $cs[.] != 0 or $cs[. - 1] != 0) | $cs[.]]
  | map(if . == 0 then 32 else . end)
  | implode;

def sql_clipped($chars; $bytes):
  (. // "" | tostring | sql_controls_collapsed) as $clean
  | ($clean | .[:$chars] | until(utf8bytelength <= $bytes; .[:-1])) as $cut
  | if $cut == $clean then $clean else ($cut | .[:$chars - 1]) + "…" end;
'

dashboard_get() {
  local response
  response=$(request api_get "/2.0/lakeview/dashboards/$1")
  printf '%s' "$response" |
    jq -ce "$preamble$dashboard_doc"'
      dashboard_doc as $doc
      | ([$doc.datasets[]?]) as $datasets
      | ([$doc.pages[]?]) as $pages
      | {
          dashboard: {
            dashboard_id: (.dashboard_id | clipped(40; 40)),
            display_name: (.display_name | clipped(60; 100)),
            lifecycle_state: (.lifecycle_state // "" | clipped(24; 24)),
            create_time: (.create_time // "" | clipped(40; 40)),
            update_time: (.update_time // "" | clipped(40; 40)),
            warehouse_id: (if .warehouse_id then (.warehouse_id | clipped(40; 40)) else null end),
            path: (if .path then (.path | clipped(80; 160)) else null end),
            datasets: [
              $datasets[:10][]
              | {
                  name: (.name | clipped(24; 32)),
                  display_name: (.displayName | clipped(40; 60)),
                  parameter_keywords: [(.parameters // [])[:4][] | (.keyword | clipped(24; 24))]
                }
            ],
            datasets_omitted: ([($datasets | length) - 10, 0] | max),
            pages: [
              $pages[:6][]
              | {name: (.name | clipped(24; 32)), display_name: (.displayName | clipped(40; 60))}
            ],
            pages_omitted: ([($pages | length) - 6, 0] | max)
          }
        }'
}

dashboard_sql() {
  local dashboard_id=$1 dataset=$2
  local response
  response=$(request api_get "/2.0/lakeview/dashboards/$dashboard_id")
  printf '%s' "$response" |
    jq -ce --arg dataset "$dataset" "$preamble$dashboard_doc"'
      dashboard_doc as $doc
      | ([$doc.datasets[]? | select(.name == $dataset or .displayName == $dataset)] | first) as $found
      | if $found == null then
          error("dataset \($dataset | clipped(60; 100) | tojson) is not in this dashboard — available: "
            + ([$doc.datasets[]? | .displayName // .name | clipped(40; 60)] | join(", ")))
        else
          ($found | dataset_sql) as $sql
          | {
              dashboard_id: (.dashboard_id | clipped(40; 40)),
              dataset: {
                name: ($found.name | clipped(24; 32)),
                display_name: ($found.displayName | clipped(40; 60))
              },
              sql: ($sql | sql_clipped(2800; 2800)),
              sql_bytes_total: ($sql | utf8bytelength),
              sql_truncated: (($sql | sql_clipped(2800; 2800)) != $sql),
              parameters: [
                ($found.parameters // [])[:6][]
                | {keyword: (.keyword | clipped(24; 24)), display_name: (.displayName | clipped(40; 60))}
              ]
            }
        end'
}

# ── SQL warehouses ──────────────────────────────────────────────────────────

readonly warehouse_projection='
def warehouse_row:
  {
    id: (.id | clipped(40; 40)),
    name: (.name | clipped(60; 100)),
    state: (.state // "" | clipped(24; 24)),
    cluster_size: (.cluster_size // "" | clipped(24; 24)),
    num_clusters: (.num_clusters // 0),
    auto_stop_mins: (.auto_stop_mins // 0),
    serverless: (.enable_serverless_compute == true),
    warehouse_type: (.warehouse_type // "" | clipped(24; 24)),
    health_status: (if .health.status then (.health.status | clipped(24; 24)) else null end)
  };

def warehouse_state:
  {
    id: (.id | clipped(40; 40)),
    name: (.name | clipped(60; 100)),
    state: (.state // "" | clipped(24; 24)),
    num_clusters: (.num_clusters // 0)
  };
'

warehouses_list() {
  local page_size=$1 page_token=$2
  set -- --data-urlencode "page_size=$page_size"
  [[ -z "$page_token" ]] || set -- "$@" --data-urlencode "page_token=$page_token"
  local response
  response=$(request api_get_q "/2.0/sql/warehouses" "$@")
  printf '%s' "$response" |
    jq -ce "$preamble$warehouse_projection"'
      {warehouses: [.warehouses[]? | warehouse_row], next_page_cursor: cursor_of}'
}

warehouse_get() {
  local response
  response=$(request api_get "/2.0/sql/warehouses/$1")
  printf '%s' "$response" |
    jq -ce "$preamble"'
      {
        warehouse: {
          id: (.id | clipped(40; 40)),
          name: (.name | clipped(60; 100)),
          state: (.state // "" | clipped(24; 24)),
          cluster_size: (.cluster_size // "" | clipped(24; 24)),
          min_num_clusters: (.min_num_clusters // 1),
          max_num_clusters: (.max_num_clusters // 1),
          num_clusters: (.num_clusters // 0),
          auto_stop_mins: (.auto_stop_mins // 0),
          serverless: (.enable_serverless_compute == true),
          warehouse_type: (.warehouse_type // "" | clipped(24; 24)),
          creator: (.creator_name | clipped(60; 100)),
          health: (
            if .health.status then
              {
                status: (.health.status | clipped(24; 24)),
                summary: (if .health.summary then (.health.summary | clipped(160; 320)) else null end),
                failure_code: (if .health.failure_reason.code then (.health.failure_reason.code | clipped(60; 60)) else null end)
              }
            else null
            end
          )
        }
      }'
}

# Start and stop answer an empty body before the warehouse moves, so the
# re-read reports the state it actually reached — usually STARTING/STOPPING.
warehouse_action() {
  local verb=$1 warehouse_id=$2
  request api_post "/2.0/sql/warehouses/$warehouse_id/$verb" >/dev/null
  local response
  response=$(request api_get "/2.0/sql/warehouses/$warehouse_id")
  printf '%s' "$response" |
    jq -ce "$preamble$warehouse_projection"'{warehouse: warehouse_state}'
}

# ── jobs ────────────────────────────────────────────────────────────────────

# Job runs report state twice: the deprecated state object and the current
# status object. Read status first and fall back, so the projection survives
# whichever the workspace emits.
readonly run_projection='
def run_state: (.status.state // .state.life_cycle_state // "");

def run_result: (.status.termination_details.code // .state.result_state // null);

def run_message($chars; $bytes):
  (.status.termination_details.message // .state.state_message // "" | clipped($chars; $bytes));

def duration_of: (if .run_duration then .run_duration elif .execution_duration then .execution_duration else null end);
'

jobs_list() {
  local name=$1 page_size=$2 page_token=$3
  set -- --data-urlencode "limit=$page_size"
  [[ -z "$name" ]] || set -- "$@" --data-urlencode "name=$name"
  [[ -z "$page_token" ]] || set -- "$@" --data-urlencode "page_token=$page_token"
  local response
  response=$(request api_get_q "/2.2/jobs/list" "$@")
  printf '%s' "$response" |
    jq -ce "$preamble"'
      {
        jobs: [
          .jobs[]?
          | {
              job_id: .job_id,
              name: (.settings.name | clipped(60; 100)),
              creator: (.creator_user_name | clipped(60; 100)),
              created_time: (.created_time // null)
            }
        ],
        next_page_cursor: cursor_of
      }'
}

# One task type key names each task's kind; probing the known ones keeps the
# projection additive when Databricks grows a new type — it reads as "other".
job_get() {
  local response
  response=$(request api_get_q "/2.2/jobs/get" --data-urlencode "job_id=$1")
  printf '%s' "$response" |
    jq -ce "$preamble"'
      def task_kind:
        if .notebook_task then "notebook"
        elif .spark_python_task then "python"
        elif .python_wheel_task then "python_wheel"
        elif .spark_jar_task then "jar"
        elif .spark_submit_task then "spark_submit"
        elif .sql_task then "sql"
        elif .dbt_task then "dbt"
        elif .pipeline_task then "pipeline"
        elif .run_job_task then "run_job"
        elif .condition_task then "condition"
        elif .for_each_task then "for_each"
        else "other"
        end;
      ([.settings.tasks[]?]) as $tasks
      | {
          job: {
            job_id: .job_id,
            name: (.settings.name | clipped(60; 100)),
            creator: (if .creator_user_name then (.creator_user_name | clipped(60; 100)) else null end),
            run_as: (if .run_as_user_name then (.run_as_user_name | clipped(60; 100)) else null end),
            max_concurrent_runs: (.settings.max_concurrent_runs // null),
            schedule: (
              if .settings.schedule.quartz_cron_expression then
                {
                  cron: (.settings.schedule.quartz_cron_expression | clipped(60; 60)),
                  timezone: (.settings.schedule.timezone_id // "" | clipped(30; 30)),
                  paused: (.settings.schedule.pause_status == "PAUSED")
                }
              else null
              end
            ),
            parameters: [
              (.settings.parameters // [])[:8][]
              | {name: (.name | clipped(30; 40)), default: (.default | clipped(40; 60))}
            ],
            tasks: [
              $tasks[:12][]
              | {
                  task_key: (.task_key | clipped(40; 60)),
                  kind: task_kind,
                  depends_on: [(.depends_on // [])[:2][] | (.task_key | clipped(40; 60))]
                }
            ],
            tasks_omitted: ([($tasks | length) - 12, 0] | max)
          }
        }'
}

job_runs_list() {
  local job_id=$1 active_only=$2 completed_only=$3 page_size=$4 page_token=$5
  [[ "$active_only" == "true" && "$completed_only" == "true" ]] &&
    fail "active_only and completed_only are mutually exclusive"
  set -- --data-urlencode "limit=$page_size"
  [[ "$job_id" == "0" ]] || set -- "$@" --data-urlencode "job_id=$job_id"
  [[ "$active_only" != "true" ]] || set -- "$@" --data-urlencode "active_only=true"
  [[ "$completed_only" != "true" ]] || set -- "$@" --data-urlencode "completed_only=true"
  [[ -z "$page_token" ]] || set -- "$@" --data-urlencode "page_token=$page_token"
  local response
  response=$(request api_get_q "/2.2/jobs/runs/list" "$@")
  printf '%s' "$response" |
    jq -ce "$preamble$run_projection"'
      {
        runs: [
          .runs[]?
          | {
              run_id: .run_id,
              job_id: .job_id,
              state: (run_state | clipped(24; 24)),
              result: run_result,
              message: run_message(60; 100),
              start_time: (.start_time // null),
              duration_ms: duration_of
            }
        ],
        next_page_cursor: cursor_of
      }'
}

job_run_get() {
  local response
  response=$(request api_get_q "/2.2/jobs/runs/get" --data-urlencode "run_id=$1")
  printf '%s' "$response" |
    jq -ce "$preamble$run_projection"'
      ([.tasks[]?]) as $tasks
      | {
          run: {
            run_id: .run_id,
            job_id: .job_id,
            run_name: (.run_name | clipped(60; 100)),
            state: (run_state | clipped(24; 24)),
            result: run_result,
            message: run_message(100; 160),
            start_time: (.start_time // null),
            end_time: (if .end_time then (if .end_time == 0 then null else .end_time end) else null end),
            duration_ms: duration_of,
            tasks: [
              $tasks[:10][]
              | {
                  task_key: (.task_key | clipped(40; 60)),
                  run_id: (.run_id // null),
                  state: (run_state | clipped(24; 24)),
                  result: run_result,
                  duration_ms: duration_of
                }
            ],
            tasks_omitted: ([($tasks | length) - 10, 0] | max)
          }
        }'
}

job_run_output() {
  local run_id=$1
  local response
  response=$(request api_get_q "/2.2/jobs/runs/get-output" --data-urlencode "run_id=$run_id")
  printf '%s' "$response" |
    jq -ce --argjson run_id "$run_id" "$preamble$run_projection"'
      {
        run_id: $run_id,
        state: (.metadata | run_state | clipped(24; 24)),
        result: (.metadata | run_result),
        error: (if .error then (.error | clipped(150; 200)) else null end),
        error_trace_tail: (.error_trace | tail_lines(10; 80; 120)),
        logs_tail: (.logs | tail_lines(6; 80; 120)),
        logs_truncated: (.logs_truncated == true),
        notebook_result: (if .notebook_output.result then (.notebook_output.result | clipped(200; 300)) else null end),
        notebook_result_truncated: (.notebook_output.truncated == true)
      }'
}

# The idempotency token is forwarded so a retried dispatch cannot double-run
# the job; the run state comes from a re-read because run-now only answers
# the new run's ID.
job_run_now() {
  local job_id=$1 idempotency_token=$2 run_id body
  shift 2
  body=$(jq -nc --argjson job_id "$job_id" --arg token "$idempotency_token" '
    {job_id: $job_id}
    + (if $token == "" then {} else {idempotency_token: $token} end)
    + (if ($ARGS.positional | length) > 0 then
        {job_parameters: ($ARGS.positional | map(
          index("=") as $i
          | if $i == null or $i == 0 then error("job_params entries must be name=value pairs")
            else {key: .[:$i], value: .[$i + 1:]}
            end) | from_entries)}
      else {} end)' --args "$@")
  local created
  created=$(request api_post "/2.2/jobs/run-now" "$body")
  run_id=$(printf '%s' "$created" | jq -e '.run_id')
  local response
  response=$(request api_get_q "/2.2/jobs/runs/get" --data-urlencode "run_id=$run_id")
  printf '%s' "$response" |
    jq -ce "$preamble$run_projection"'
      {run_id: .run_id, job_id: .job_id, state: (run_state | clipped(24; 24))}'
}

job_run_cancel() {
  local run_id=$1
  request api_post "/2.2/jobs/runs/cancel" "$(jq -nc --argjson run_id "$run_id" '{run_id: $run_id}')" >/dev/null
  local response
  response=$(request api_get_q "/2.2/jobs/runs/get" --data-urlencode "run_id=$run_id")
  printf '%s' "$response" |
    jq -ce "$preamble$run_projection"'
      {run: {run_id: .run_id, state: (run_state | clipped(24; 24)), result: run_result}}'
}

# ── clusters ────────────────────────────────────────────────────────────────

readonly cluster_projection='
def cluster_state_of:
  {
    cluster_id: (.cluster_id | clipped(60; 60)),
    name: (.cluster_name | clipped(60; 100)),
    state: (.state // "" | clipped(24; 24)),
    state_message: (.state_message | clipped(100; 160))
  };
'

clusters_list() {
  local state=$1 page_size=$2 page_token=$3
  set -- --data-urlencode "page_size=$page_size"
  [[ -z "$state" ]] || set -- "$@" --data-urlencode "filter_by.cluster_states=$state"
  [[ -z "$page_token" ]] || set -- "$@" --data-urlencode "page_token=$page_token"
  local response
  response=$(request api_get_q "/2.1/clusters/list" "$@")
  printf '%s' "$response" |
    jq -ce "$preamble"'
      {
        clusters: [
          .clusters[]?
          | {
              cluster_id: (.cluster_id | clipped(60; 60)),
              name: (.cluster_name | clipped(60; 100)),
              state: (.state // "" | clipped(24; 24)),
              spark_version: (.spark_version // "" | clipped(24; 24)),
              node_type: (.node_type_id // "" | clipped(24; 24)),
              num_workers: (.num_workers // null),
              autoscale: (
                if .autoscale then
                  {min_workers: (.autoscale.min_workers // 0), max_workers: (.autoscale.max_workers // 0)}
                else null
                end
              ),
              source: (.cluster_source // "" | clipped(24; 24))
            }
        ],
        next_page_cursor: cursor_of
      }'
}

cluster_get() {
  local response
  response=$(request api_get_q "/2.1/clusters/get" --data-urlencode "cluster_id=$1")
  printf '%s' "$response" |
    jq -ce "$preamble"'
      {
        cluster: {
          cluster_id: (.cluster_id | clipped(60; 60)),
          name: (.cluster_name | clipped(60; 100)),
          state: (.state // "" | clipped(24; 24)),
          state_message: (.state_message | clipped(100; 160)),
          spark_version: (.spark_version // "" | clipped(30; 40)),
          node_type: (.node_type_id // "" | clipped(30; 40)),
          driver_node_type: (if .driver_node_type_id then (.driver_node_type_id | clipped(30; 40)) else null end),
          num_workers: (.num_workers // null),
          autoscale: (
            if .autoscale then
              {min_workers: (.autoscale.min_workers // 0), max_workers: (.autoscale.max_workers // 0)}
            else null
            end
          ),
          autotermination_minutes: (.autotermination_minutes // null),
          creator: (if .creator_user_name then (.creator_user_name | clipped(40; 60)) else null end),
          source: (.cluster_source // "" | clipped(24; 24)),
          start_time: (.start_time // null),
          terminated_time: (if .terminated_time then (if .terminated_time == 0 then null else .terminated_time end) else null end),
          termination_reason: (
            if .termination_reason.code then
              {
                code: (.termination_reason.code | clipped(60; 60)),
                type: (if .termination_reason.type then (.termination_reason.type | clipped(24; 24)) else null end)
              }
            else null
            end
          )
        }
      }'
}

# A read the API serves over POST; the body only ever carries the id, the
# page bounds, and the newest-first order.
cluster_events() {
  local cluster_id=$1 page_size=$2 page_token=$3 body
  body=$(jq -nc --arg cluster_id "$cluster_id" --argjson page_size "$page_size" --arg token "$page_token" '
    {cluster_id: $cluster_id, page_size: $page_size, order: "DESC"}
    + (if $token == "" then {} else {page_token: $token} end)')
  local response
  response=$(request api_post "/2.1/clusters/events" "$body")
  printf '%s' "$response" |
    jq -ce "$preamble"'
      {
        events: [
          .events[]?
          | {
              timestamp: (.timestamp // null),
              type: (.type // "" | clipped(48; 48)),
              user: (if .details.user then (.details.user | clipped(40; 60)) else null end),
              reason_code: (if .details.reason.code then (.details.reason.code | clipped(60; 60)) else null end),
              current_workers: (.details.current_num_workers // null),
              target_workers: (.details.target_num_workers // null)
            }
        ],
        next_page_cursor: cursor_of
      }'
}

# Start and restart answer an empty body immediately — and are documented
# no-ops when the cluster is not TERMINATED (start) or not RUNNING (restart) —
# so the re-read is the only truthful result.
cluster_action() {
  local verb=$1 cluster_id=$2
  request api_post "/2.1/clusters/$verb" "$(jq -nc --arg cluster_id "$cluster_id" '{cluster_id: $cluster_id}')" >/dev/null
  local response
  response=$(request api_get_q "/2.1/clusters/get" --data-urlencode "cluster_id=$cluster_id")
  printf '%s' "$response" |
    jq -ce "$preamble$cluster_projection"'{cluster: cluster_state_of}'
}

# Checked here at the top level: a fail inside a $(command substitution) in a
# curl argument cannot abort the curl around it.
[[ -n "${DATABRICKS_HOST:-}" ]] || fail "DATABRICKS_HOST is not set — allowlist it in the runner's inherit_env"
[[ -n "${DATABRICKS_TOKEN:-}" ]] || fail "DATABRICKS_TOKEN is not set — allowlist it in the runner's inherit_env"

mode=${1:-}
case "$mode" in
  whoami)
    whoami_me
    ;;
  sql_query)
    sql_query "$2" "$3" "$4" "$5" "$6" "$7"
    ;;
  sql_statement)
    sql_statement "$2"
    ;;
  sql_statement_cancel)
    sql_statement_cancel "$2"
    ;;
  catalogs_list)
    catalogs_list "$2" "$3"
    ;;
  schemas_list)
    schemas_list "$2" "$3" "$4"
    ;;
  tables_list)
    tables_list "$2" "$3" "$4" "$5"
    ;;
  table_get)
    table_get "$2"
    ;;
  dashboards_list)
    dashboards_list "$2" "$3"
    ;;
  dashboard_get)
    dashboard_get "$2"
    ;;
  dashboard_sql)
    dashboard_sql "$2" "$3"
    ;;
  warehouses_list)
    warehouses_list "$2" "$3"
    ;;
  warehouse_get)
    warehouse_get "$2"
    ;;
  warehouse_start | warehouse_stop)
    warehouse_action "${mode#warehouse_}" "$2"
    ;;
  jobs_list)
    jobs_list "$2" "$3" "$4"
    ;;
  job_get)
    job_get "$2"
    ;;
  job_runs_list)
    job_runs_list "$2" "$3" "$4" "$5" "$6"
    ;;
  job_run_get)
    job_run_get "$2"
    ;;
  job_run_output)
    job_run_output "$2"
    ;;
  job_run_now)
    shift
    job_run_now "$@"
    ;;
  job_run_cancel)
    job_run_cancel "$2"
    ;;
  clusters_list)
    clusters_list "$2" "$3" "$4"
    ;;
  cluster_get)
    cluster_get "$2"
    ;;
  cluster_events)
    cluster_events "$2" "$3" "$4"
    ;;
  cluster_start | cluster_restart)
    cluster_action "${mode#cluster_}" "$2"
    ;;
  *)
    fail "unsupported Databricks operation"
    ;;
esac

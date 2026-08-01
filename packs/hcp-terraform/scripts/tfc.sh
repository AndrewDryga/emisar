#!/bin/bash
# tfc.sh — packaged with the "hcp-terraform" emisar pack. emisar loads it from
# disk when the pack is trusted, journals its SHA-256 with every run, and runs
# it via the interpreter named in each action. It is never fetched or assembled
# at request time.
#
# One authenticated exchange with the HCP Terraform / Terraform Enterprise
# JSON:API. $TFE_ADDRESS is the API host (defaults to HCP Terraform) and
# $TFE_TOKEN is streamed as an Authorization header over stdin (-H @-), so the
# token never lands in argv, a `ps` listing, or the audit log.
set -euo pipefail

readonly max_response_bytes=33554432
readonly max_log_tail_lines=200
readonly max_log_tail_bytes=65536

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

api_base() {
  printf '%s/api/v2' "${TFE_ADDRESS:-https://app.terraform.io}"
}

# --fail-with-body keeps the JSON:API error document while still exiting
# non-zero, so a rejected apply reports the reason instead of failing blank.
# Plain --fail would throw the body away. Needs curl 7.76 or newer.
api_get() {
  printf 'Authorization: Bearer %s\n' "${TFE_TOKEN:-}" |
    curl --fail-with-body -sS -H @- "$(api_base)$1"
}

# The json-output endpoint answers with a one-minute redirect to blob storage.
# curl drops the Authorization header on a cross-host redirect by default, which
# is what we want: the redirect target is already presigned.
api_get_following_redirect() {
  printf 'Authorization: Bearer %s\n' "${TFE_TOKEN:-}" |
    curl --fail-with-body -sSL -H @- "$(api_base)$1"
}

api_post() {
  printf 'Authorization: Bearer %s\n' "${TFE_TOKEN:-}" |
    curl --fail-with-body -sS -X POST -H @- \
      -H 'Content-Type: application/vnd.api+json' \
      --data "$2" "$(api_base)$1"
}

request() {
  local response status=0
  response=$("$@") || status=$?
  if ((status != 0)); then
    printf '%s\n' "$response" >&2
    fail "HCP Terraform rejected the request — request exit status $status"
  fi
  ((${#response} <= max_response_bytes)) || fail "API response exceeded 32 MiB"
  printf '%s' "$response"
}

require_id() {
  local kind=$1 value=$2 prefix=$3
  [[ "$value" == "$prefix"* ]] || fail "$kind must be a $prefix… identifier"
}

# Pagination is explicit: every list returns the API's next page number, or null
# on the last page, so a caller can page on rather than silently seeing a slice.
#
# clipped bounds the free-text fields (run messages carry whole CI commit
# lines): the runner rejects a structured result over 8 KiB, so a page at the
# maximum advertised page_size must fit it in the worst case. Control bytes
# collapse to one space, then the value is cut to $chars codepoints AND $bytes
# UTF-8 bytes — JSON escaping can double bytes (quote, backslash, U+2028/29),
# so the byte bound is what the page arithmetic in each action relies on — with
# an ellipsis marking the cut.
readonly pagination='
def next_page: (.meta.pagination["next-page"] // null);

def clipped($chars; $bytes):
  (. // "" | tostring | gsub("[[:cntrl:]]+"; " ")) as $clean
  | ($clean | .[:$chars] | until(utf8bytelength <= $bytes; .[:-1])) as $cut
  | if $cut == $clean then $clean else ($cut | .[:$chars - 1]) + "…" end;

def actions_of($attributes):
  {
    confirmable: ($attributes.actions["is-confirmable"] == true),
    discardable: ($attributes.actions["is-discardable"] == true),
    cancelable: ($attributes.actions["is-cancelable"] == true)
  };

def run_of($run):
  $run.attributes as $a
  | {
      id: $run.id,
      status: ($a.status // ""),
      message: ($a.message | clipped(100; 160)),
      is_destroy: ($a["is-destroy"] == true),
      plan_only: ($a["plan-only"] == true),
      has_changes: ($a["has-changes"] == true),
      source: ($a.source // ""),
      created_at: ($a["created-at"] // ""),
      workspace_id: ($run.relationships.workspace.data.id // ""),
      actions: actions_of($a)
    };
'

# The same shape terraform-readonly returns for a local plan, so an operator or
# an agent reads one summary format whether the plan ran on a runner or in HCP
# Terraform. Each pack is installed and hashed on its own, so the projection is
# necessarily packaged with both rather than shared.
#
# The runner rejects a structured result over 8 KiB and a production plan
# carries hundreds of resource changes, so each list keeps a bounded sample —
# most destructive first, so a truncated review can never hide the deletes —
# and `truncated` counts the entries each list dropped. `summary` is computed
# from the full arrays before capping and stays the authoritative totals. The
# clip and cap sizes are chosen so every list at its cap fits the cap with
# headroom even when every field is at its escaped worst (JSON escaping can
# double a byte-bound string).
readonly plan_projection='
def summarize($changes; $drift):
  {
    total: ($changes | length),
    create: ($changes | map(select(.action == "create")) | length),
    update: ($changes | map(select(.action == "update")) | length),
    delete: ($changes | map(select(.action == "delete")) | length),
    replace: ($changes | map(select(.action == "replace")) | length),
    read: ($changes | map(select(.action == "read")) | length),
    import: ($changes | map(select(.action == "import")) | length),
    drifted: ($drift | length)
  };

# Terraform spells an unchanged item "no-op" in this format and "noop" in the
# CLI message stream. terraform-readonly meets both; match both here too so the
# two packs cannot report the same plan differently.
def is_noop($action): $action == "no-op" or $action == "noop";

def norm_action($actions):
  ($actions // []) as $a
  | if ($a | sort) == ["create", "delete"] then "replace"
    elif ($a | length) == 1 then $a[0]
    else ($a | join("+"))
    end;

def destruction_rank: {"delete": 0, "replace": 1, "update": 2, "create": 3, "read": 4, "import": 5};

def most_destructive_first: sort_by([(destruction_rank[.action] // 6), .address]);

def omitted($entries; $cap): [($entries | length) - $cap, 0] | max;

def clip_resource:
  .address |= clipped(80; 80)
  | .resource_type |= clipped(44; 44)
  | .module |= clipped(32; 32)
  | .action |= clipped(12; 12);

def project_plan:
  . as $plan
  | [ $plan.resource_changes[]?
      | {
          address: (.address // ""),
          resource_type: (.type // ""),
          module: (.module_address // ""),
          action: norm_action(.change.actions),
          reason: (.action_reason // "")
        }
      | select(is_noop(.action) | not)
    ] as $changes
  | [ $plan.resource_drift[]?
      | {
          address: (.address // ""),
          resource_type: (.type // ""),
          module: (.module_address // ""),
          action: norm_action(.change.actions)
        }
      | select(is_noop(.action) | not)
    ] as $drift
  | [ ($plan.output_changes // {})
      | to_entries[]
      | {
          name: .key,
          action: norm_action(.value.actions),
          sensitive: ((.value.after_sensitive == true) or (.value.before_sensitive == true))
        }
      | select(is_noop(.action) | not)
    ] as $outputs
  | {
      source: "hcp_plan",
      cli_version: ($plan.terraform_version | clipped(32; 32)),
      summary: summarize($changes; $drift),
      changes: ($changes | most_destructive_first | .[:10] | map(clip_resource | .reason |= clipped(36; 36))),
      drift: ($drift | most_destructive_first | .[:3] | map(clip_resource)),
      outputs: ($outputs | .[:4] | map(.name |= clipped(40; 40) | .action |= clipped(12; 12))),
      truncated: {
        changes: omitted($changes; 10),
        drift: omitted($drift; 3),
        outputs: omitted($outputs; 4)
      }
    };
'

# A run fails in a phase, not as a whole: the apply when it errored, otherwise
# the plan. Both phases can be canceled mid-flight, so canceled counts as
# failed; a run with neither has nothing to diagnose.
readonly diagnostics_selection='
def included_first($type): [(.included // [])[] | select(.type == $type)] | first;

def phase_failed($doc):
  $doc != null and (($doc.attributes.status // "") | . == "errored" or . == "canceled");

def chosen_phase:
  included_first("applies") as $apply
  | included_first("plans") as $plan
  | if phase_failed($apply) then {name: "apply", doc: $apply}
    elif phase_failed($plan) then {name: "plan", doc: $plan}
    else null
    end;
'

# Terraform streams ANSI color and cursor sequences into its logs; strip CSI
# sequences, then every remaining control byte except tab and newline, so a
# hostile log cannot smuggle terminal escapes into the result or the audit.
sanitize_log() {
  sed $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' | tr -d '\000-\010\013-\037\177'
}

# The phase's log-read-url is a presigned credential: it reaches curl through a
# config document on stdin, never argv, output, stderr, or the audit trail. An
# absent, malformed, or unreadable log reports why instead of failing the whole
# diagnosis — the phase status and timestamps are still worth returning.
#
# --globoff is a credential control, not a nicety: curl expands {a,b} in a URL
# into one transfer per alternative, so an API answering with a braced host list
# would send the presigned signature to every host in it. The shape check
# rejects braces (never legitimate in a URL) and --globoff refuses to expand
# whatever else arrives, while still letting an IPv6 literal host through.
# The log is read to its end because the tail is the useful part, so the
# transfer is bounded by time rather than --max-filesize, which would turn a
# legitimately large apply log into an unreadable one.
fetch_log_tail() {
  local url=$1 url_shape='^https?://[^[:space:]"\\{}]+$' tail_text status=0
  if [[ -z "$url" ]]; then
    jq -nc '{available: false, reason: "HCP returned no log for this phase"}'
    return
  fi
  if [[ ! "$url" =~ $url_shape ]]; then
    jq -nc '{available: false, reason: "HCP returned a malformed log URL"}'
    return
  fi
  tail_text=$(printf 'url = "%s"\n' "$url" |
    curl -q --fail -s --globoff --proto '=http,https' \
      --connect-timeout 10 --max-time 90 -K - |
    tail -c $((max_log_tail_bytes * 4)) |
    sanitize_log |
    tail -n "$max_log_tail_lines" |
    tail -c "$max_log_tail_bytes") || status=$?
  if ((status != 0)); then
    jq -nc '{available: false, reason: "the log is gone or this token may not read it"}'
    return
  fi
  printf '%s' "$tail_text" |
    jq -Rsc '{available: true, tail: (if . == "" then [] else split("\n") end)}'
}

run_diagnostics() {
  local run_id=$1 response phase log_url log_json
  require_id "run_id" "$run_id" "run-"
  response=$(request api_get "/runs/$run_id?include=plan,apply")

  phase=$(printf '%s' "$response" |
    jq -r "$diagnostics_selection"'chosen_phase | if . == null then "" else .name end')
  if [[ -z "$phase" ]]; then
    local run_status
    run_status=$(printf '%s' "$response" | jq -r '.data.attributes.status // "unknown"')
    fail "run $run_id has no errored or canceled plan or apply phase to diagnose (run status: $run_status)"
  fi

  log_url=$(printf '%s' "$response" |
    jq -r "$diagnostics_selection"'chosen_phase.doc.attributes["log-read-url"] // ""')
  log_json=$(fetch_log_tail "$log_url")

  printf '%s' "$response" |
    jq -ce --argjson log "$log_json" "$pagination$diagnostics_selection"'
      chosen_phase as $phase
      | $phase.doc.attributes as $a
      | ($a["status-timestamps"] // {}) as $ts
      | {
          run: run_of(.data),
          phase: $phase.name,
          diagnostics: {
            status: ($a.status // ""),
            started_at: ($ts["started-at"] // ""),
            ended_at: ($ts["errored-at"] // $ts["canceled-at"] // $ts["finished-at"] // "")
          },
          log: $log
        }'
}

# Retry is deliberately not generic run creation: the workspace and the
# configuration version come only from the fetched source run, the source must
# already be terminal, and both safety gates are explicit in the POST body so
# the new run cannot apply anything without a human tfc.apply_run.
retry_run() {
  local source_run_id=$1 message=$2 response source_status workspace_id configuration_version_id body
  require_id "source_run_id" "$source_run_id" "run-"
  response=$(request api_get "/runs/$source_run_id")

  source_status=$(printf '%s' "$response" | jq -r '.data.attributes.status // ""')
  case "$source_status" in
    errored | canceled | force_canceled | discarded) ;;
    *)
      fail "source run $source_run_id is '$source_status' — retry only re-runs an errored, canceled, force_canceled, or discarded run"
      ;;
  esac

  workspace_id=$(printf '%s' "$response" | jq -r '.data.relationships.workspace.data.id // ""')
  configuration_version_id=$(printf '%s' "$response" |
    jq -r '.data.relationships["configuration-version"].data.id // ""')
  require_id "the source run's workspace" "$workspace_id" "ws-"
  require_id "the source run's configuration version" "$configuration_version_id" "cv-"

  body=$(jq -nc --arg workspace "$workspace_id" --arg configuration_version "$configuration_version_id" \
    --arg message "$message" '
    {
      data: {
        type: "runs",
        attributes: (
          {"plan-only": false, "auto-apply": false}
          + (if $message == "" then {} else {message: $message} end)
        ),
        relationships: {
          workspace: {data: {type: "workspaces", id: $workspace}},
          "configuration-version": {data: {type: "configuration-versions", id: $configuration_version}}
        }
      }
    }')
  request api_post "/runs" "$body" |
    jq -ce --arg source "$source_run_id" --arg configuration_version "$configuration_version_id" \
      "$pagination"'{run: run_of(.data), source_run_id: $source, configuration_version_id: $configuration_version}'
}

list_organizations() {
  request api_get "/organizations?page%5Bsize%5D=$1&page%5Bnumber%5D=$2" |
    jq -ce "$pagination"'
      {
        organizations: [
          .data[]?
          | {name: .id, email: (.attributes.email | clipped(100; 140)), created_at: (.attributes["created-at"] // "")}
        ],
        next_page: next_page
      }'
}

list_workspaces() {
  local organization=$1
  request api_get "/organizations/$organization/workspaces?page%5Bsize%5D=$2&page%5Bnumber%5D=$3" |
    jq -ce "$pagination"'
      {
        workspaces: [
          .data[]?
          | .attributes as $a
          | {
              id: .id,
              name: ($a.name | clipped(90; 180)),
              execution_mode: ($a["execution-mode"] // ""),
              terraform_version: ($a["terraform-version"] | clipped(64; 128)),
              auto_apply: ($a["auto-apply"] == true),
              locked: ($a.locked == true),
              resource_count: ($a["resource-count"] // 0),
              updated_at: ($a["updated-at"] // "")
            }
        ],
        next_page: next_page
      }'
}

list_runs() {
  local workspace_id=$1
  require_id "workspace_id" "$workspace_id" "ws-"
  request api_get "/workspaces/$workspace_id/runs?page%5Bsize%5D=$2&page%5Bnumber%5D=$3" |
    jq -ce "$pagination"'{runs: [.data[]? | run_of(.)], next_page: next_page}'
}

# include=plan carries the plan's resource counts, which is the review a plain
# "read runs" token can see: the structured plan JSON needs workspace admin.
run_details() {
  local run_id=$1
  require_id "run_id" "$run_id" "run-"
  request api_get "/runs/$run_id?include=plan" |
    jq -ce "$pagination"'
      (.included // []) as $included
      | ([$included[] | select(.type == "plans")] | first) as $plan
      | {
          run: run_of(.data),
          plan: (
            if $plan == null then null
            else
              $plan.attributes as $p
              | {
                  id: $plan.id,
                  status: ($p.status // ""),
                  has_changes: ($p["has-changes"] == true),
                  resource_additions: ($p["resource-additions"] // 0),
                  resource_changes: ($p["resource-changes"] // 0),
                  resource_destructions: ($p["resource-destructions"] // 0),
                  resource_imports: ($p["resource-imports"] // 0)
                }
            end
          )
        }'
}

plan_summary() {
  local run_id=$1
  require_id "run_id" "$run_id" "run-"
  request api_get_following_redirect "/runs/$run_id/plan/json-output" |
    jq -ce "$pagination$plan_projection"' project_plan'
}

# Re-read the run rather than reporting what we hoped would happen: a 202 to an
# action endpoint carries no body, and the resulting state is the useful answer.
run_state() {
  local run_id=$1
  request api_get "/runs/$run_id" | jq -ce "$pagination"'{run: run_of(.data)}'
}

comment_body() {
  jq -nc --arg comment "$1" 'if $comment == "" then {} else {comment: $comment} end'
}

run_action() {
  local verb=$1 run_id=$2 comment=$3
  require_id "run_id" "$run_id" "run-"
  request api_post "/runs/$run_id/actions/$verb" "$(comment_body "$comment")" >/dev/null
  run_state "$run_id"
}

create_plan_only_run() {
  local workspace_id=$1 message=$2 body
  require_id "workspace_id" "$workspace_id" "ws-"
  body=$(jq -nc --arg workspace "$workspace_id" --arg message "$message" '
    {
      data: {
        type: "runs",
        attributes: ({"plan-only": true} + (if $message == "" then {} else {message: $message} end)),
        relationships: {workspace: {data: {type: "workspaces", id: $workspace}}}
      }
    }')
  request api_post "/runs" "$body" | jq -ce "$pagination"'{run: run_of(.data)}'
}

mode=${1:-}
case "$mode" in
  list_organizations)
    list_organizations "$2" "$3"
    ;;
  list_workspaces)
    list_workspaces "$2" "$3" "$4"
    ;;
  list_runs)
    list_runs "$2" "$3" "$4"
    ;;
  run_details)
    run_details "$2"
    ;;
  run_diagnostics)
    run_diagnostics "$2"
    ;;
  retry_run)
    retry_run "$2" "$3"
    ;;
  plan_summary)
    plan_summary "$2"
    ;;
  create_plan_only_run)
    create_plan_only_run "$2" "$3"
    ;;
  apply | discard | cancel)
    run_action "$mode" "$2" "$3"
    ;;
  *)
    fail "unsupported HCP Terraform operation"
    ;;
esac

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
readonly pagination='
def next_page: (.meta.pagination["next-page"] // null);

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
      message: ($a.message // ""),
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
readonly plan_projection='
def summarize($changes):
  {
    total: ($changes | length),
    create: ($changes | map(select(.action == "create")) | length),
    update: ($changes | map(select(.action == "update")) | length),
    delete: ($changes | map(select(.action == "delete")) | length),
    replace: ($changes | map(select(.action == "replace")) | length),
    read: ($changes | map(select(.action == "read")) | length),
    import: ($changes | map(select(.action == "import")) | length)
  };

def norm_action($actions):
  ($actions // []) as $a
  | if ($a | sort) == ["create", "delete"] then "replace"
    elif ($a | length) == 1 then $a[0]
    else ($a | join("+"))
    end;

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
      | select(.action != "no-op")
    ] as $changes
  | {
      source: "hcp_plan",
      cli_version: ($plan.terraform_version // ""),
      summary: summarize($changes),
      changes: $changes,
      drift: [
        $plan.resource_drift[]?
        | {
            address: (.address // ""),
            resource_type: (.type // ""),
            module: (.module_address // ""),
            action: norm_action(.change.actions)
          }
        | select(.action != "no-op")
      ],
      outputs: [
        ($plan.output_changes // {})
        | to_entries[]
        | {
            name: .key,
            action: norm_action(.value.actions),
            sensitive: ((.value.after_sensitive == true) or (.value.before_sensitive == true))
          }
        | select(.action != "no-op")
      ]
    };
'

list_organizations() {
  request api_get "/organizations?page%5Bsize%5D=$1&page%5Bnumber%5D=$2" |
    jq -ce "$pagination"'
      {
        organizations: [
          .data[]?
          | {name: .id, email: (.attributes.email // ""), created_at: (.attributes["created-at"] // "")}
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
              name: ($a.name // ""),
              execution_mode: ($a["execution-mode"] // ""),
              terraform_version: ($a["terraform-version"] // ""),
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
    jq -ce "$plan_projection"' project_plan'
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

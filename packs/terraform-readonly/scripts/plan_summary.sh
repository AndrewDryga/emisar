#!/bin/bash
set -euo pipefail

readonly max_plan_bytes=33554432

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

cli() {
  printf '%s' "${TF_BIN:-terraform}"
}

# The two sources carry the same plan in different shapes: `plan -json` streams
# UI messages, while `show -json` returns one document. Both project to the same
# schema, and neither ever reads an attribute or output VALUE — a saved plan
# stores those in cleartext, sensitive ones included.
readonly projection='
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

def resource_of($source):
  {
    address: ($source.addr // ""),
    resource_type: ($source.resource_type // ""),
    module: ($source.module // "")
  };

# A saved plan spells a replacement as two actions; the stream already calls it
# one. Anything unrecognized is joined rather than dropped, so a new Terraform
# action shows up in review instead of silently vanishing from the count.
def norm_action($actions):
  ($actions // []) as $a
  | if ($a | sort) == ["create", "delete"] then "replace"
    elif ($a | length) == 1 then $a[0]
    else ($a | join("+"))
    end;

def project_stream:
  . as $messages
  | [ $messages[]
      | select(.type == "planned_change")
      | .change
      | select(.action != "no-op")
      | resource_of(.resource) + {action: (.action // ""), reason: (.reason // "")}
    ] as $changes
  | {
      source: "plan",
      cli_version: (
        [$messages[] | select(.type == "version") | (.terraform // .tofu)] | first // ""
      ),
      summary: summarize($changes),
      changes: $changes,
      drift: [
        $messages[]
        | select(.type == "resource_drift")
        | .change
        | resource_of(.resource) + {action: (.action // "")}
      ],
      outputs: [
        $messages[]
        | select(.type == "outputs")
        | .outputs
        | to_entries[]
        | {name: .key, action: (.value.action // ""), sensitive: (.value.sensitive == true)}
      ],
      diagnostics: [
        $messages[]
        | select(.type == "diagnostic")
        | .diagnostic
        | {severity: (.severity // ""), summary: (.summary // "")}
      ]
    };

def project_file:
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
      source: "plan_file",
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
      ],
      diagnostics: []
    };
'

# Only severity and summary: a diagnostic detail can quote the offending
# expression, and that routinely carries a value.
report_diagnostics() {
  jq -r 'select(.type == "diagnostic") | .diagnostic | "\(.severity): \(.summary)"' \
    2>/dev/null || true
}

workspace_dir() {
  [[ -n "${TF_DIR:-}" ]] || fail "TF_DIR is required"
  [[ -d "$TF_DIR" ]] || fail "TF_DIR is not a directory"
}

live_summary() {
  local stream status=0
  workspace_dir
  stream=$(cd "$TF_DIR" && "$(cli)" plan -input=false -json) || status=$?
  ((${#stream} <= max_plan_bytes)) || fail "plan JSON stream exceeded 32 MiB"
  if ((status != 0)); then
    printf '%s\n' "$stream" | report_diagnostics >&2
    fail "plan failed with exit status $status"
  fi
  printf '%s\n' "$stream" | jq -sce "$projection"' project_stream'
}

plan_path() {
  local filename=$1
  local root plan size
  [[ -n "${TF_PLAN_DIR:-}" ]] || fail "TF_PLAN_DIR is required"
  [[ "$filename" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$ ]] ||
    fail "plan file must be a bounded basename"

  root=$(realpath -e -- "$TF_PLAN_DIR") || fail "plan directory does not exist"
  [[ "$root" != / ]] || fail "plan directory cannot be the filesystem root"
  plan=$(realpath -e -- "$root/$filename") || fail "plan file does not exist"
  [[ "$plan" == "$root/"* ]] || fail "plan file escapes the configured directory"
  [[ -f "$plan" && -r "$plan" ]] || fail "plan file must be a readable regular file"
  size=$(stat -c %s -- "$plan")
  ((size <= max_plan_bytes)) || fail "saved plan exceeded 32 MiB"
  printf '%s\n' "$plan"
}

# `show` resolves the plan's provider schemas out of the working directory, so
# it runs there even though the plan itself is addressed absolutely.
file_summary() {
  local filename=$1
  local plan document status=0
  workspace_dir
  plan=$(plan_path "$filename")
  document=$(cd "$TF_DIR" && "$(cli)" show -json "$plan") || status=$?
  ((status == 0)) || fail "reading the saved plan failed with exit status $status"
  ((${#document} <= max_plan_bytes)) || fail "plan JSON exceeded 32 MiB"
  printf '%s' "$document" | jq -ce "$projection"' project_file'
}

mode=${1:-}
case "$mode" in
  live)
    live_summary
    ;;
  file)
    file_summary "$2"
    ;;
  *)
    fail "unsupported Terraform plan projection operation"
    ;;
esac

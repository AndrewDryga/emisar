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
#
# The runner rejects a structured result over 8 KiB and a production plan
# carries hundreds of resource changes, so each list keeps a bounded sample —
# most destructive first, so a truncated review can never hide the deletes —
# and `truncated` counts the entries each list dropped. `summary` is computed
# from the full arrays before capping and stays the authoritative totals. The
# clip and cap sizes are chosen so every list at its cap fits the cap with
# headroom even when every field is at its escaped worst (JSON escaping can
# double a byte-bound string): clipped collapses control runs to one space,
# then cuts to a codepoint AND a UTF-8 byte budget with an ellipsis marking
# the cut. This is the same bounded shape the hcp-terraform pack returns; each
# pack is installed and hashed on its own, so the projection is necessarily
# packaged with both rather than shared.
readonly projection='
def clipped($chars; $bytes):
  (. // "" | tostring | gsub("[[:cntrl:]]+"; " ")) as $clean
  | ($clean | .[:$chars] | until(utf8bytelength <= $bytes; .[:-1])) as $cut
  | if $cut == $clean then $clean else ($cut | .[:$chars - 1]) + "…" end;

def destruction_rank: {"delete": 0, "replace": 1, "update": 2, "create": 3, "read": 4, "import": 5};

def most_destructive_first: sort_by([(destruction_rank[.action] // 6), .address]);

def omitted($entries; $cap): [($entries | length) - $cap, 0] | max;

def clip_resource:
  .address |= clipped(80; 80)
  | .resource_type |= clipped(44; 44)
  | .module |= clipped(32; 32)
  | .action |= clipped(12; 12);

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

# Terraform spells an unchanged item two ways depending on the source: the
# message stream says "noop" while a saved plan says "no-op". Both are review
# noise, and matching only one spelling made the two paths disagree about the
# same plan (a real workspace returned 13 unchanged outputs through one and none
# through the other).
def is_noop($action): $action == "no-op" or $action == "noop";

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

def bounded_lists($changes; $drift; $outputs; $diagnostics):
  {
    changes: ($changes | most_destructive_first | .[:10] | map(clip_resource | .reason |= clipped(36; 36))),
    drift: ($drift | most_destructive_first | .[:3] | map(clip_resource)),
    outputs: ($outputs | .[:4] | map(.name |= clipped(40; 40) | .action |= clipped(12; 12))),
    diagnostics: ($diagnostics | .[:3] | map(.severity |= clipped(12; 12) | .summary |= clipped(100; 100))),
    truncated: {
      changes: omitted($changes; 10),
      drift: omitted($drift; 3),
      outputs: omitted($outputs; 4),
      diagnostics: omitted($diagnostics; 3)
    }
  };

def project_stream:
  . as $messages
  | [ $messages[]
      | select(.type == "planned_change")
      | .change
      | select(is_noop(.action) | not)
      | resource_of(.resource) + {action: (.action // ""), reason: (.reason // "")}
    ] as $changes
  | [ $messages[]
      | select(.type == "resource_drift")
      | .change
      | select(is_noop(.action) | not)
      | resource_of(.resource) + {action: (.action // "")}
    ] as $drift
  | [ $messages[]
      | select(.type == "outputs")
      | .outputs
      | to_entries[]
      | {name: .key, action: (.value.action // ""), sensitive: (.value.sensitive == true)}
      | select(is_noop(.action) | not)
    ] as $outputs
  | [ $messages[]
      | select(.type == "diagnostic")
      | .diagnostic
      | {severity: (.severity // ""), summary: (.summary // "")}
    ] as $diagnostics
  | {
      source: "plan",
      cli_version: (
        [$messages[] | select(.type == "version") | (.terraform // .tofu)] | first | clipped(32; 32)
      ),
      summary: summarize($changes; $drift)
    } + bounded_lists($changes; $drift; $outputs; $diagnostics);

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
      source: "plan_file",
      cli_version: ($plan.terraform_version | clipped(32; 32)),
      summary: summarize($changes; $drift)
    } + bounded_lists($changes; $drift; $outputs; []);
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
  local stream messages status=0
  workspace_dir
  stream=$(cd "$TF_DIR" && "$(cli)" plan -input=false -json) || status=$?
  ((${#stream} <= max_plan_bytes)) || fail "plan JSON stream exceeded 32 MiB"
  if ((status != 0)); then
    printf '%s\n' "$stream" | report_diagnostics >&2
    fail "plan failed with exit status $status"
  fi

  # A workspace that does not plan on this host — HCP Terraform / Terraform
  # Enterprise in remote or agent execution mode — streams the run's HUMAN output
  # here and emits only the local CLI's version message as JSON, so the parseable
  # lines are a truthful-looking but EMPTY plan. Keep the non-JSON lines out, then
  # refuse to report a summary unless the run delivered its change_summary. That
  # test also passes a genuinely empty plan, which does emit one.
  messages=$(printf '%s\n' "$stream" | jq -Rnc '[inputs | fromjson? // empty]')
  if ! printf '%s' "$messages" | jq -e 'any(.[]; .type == "change_summary")' >/dev/null; then
    fail "this working directory streamed no structured plan output, so no summary can be trusted — an HCP Terraform or Terraform Enterprise workspace in remote or agent execution mode behaves this way; review those runs with the hcp-terraform pack instead"
  fi
  printf '%s' "$messages" | jq -ce "$projection"' project_stream'
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
  # Same fail-closed reasoning as the live path: a document that is valid JSON
  # but carries no plan would otherwise project as an empty, believable summary.
  printf '%s' "$document" | jq -e 'has("format_version")' >/dev/null ||
    fail "that file did not read back as a Terraform plan document"
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

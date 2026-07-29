#!/bin/bash
set -euo pipefail

readonly max_state_bytes=67108864

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

project_metadata() {
  local source=$1
  jq --arg source "$source" -ce '
    def metadata($source):
      if type != "object" then
        error("state must be a JSON object")
      elif .version != 4 then
        error("unsupported Terraform state format version")
      elif (.terraform_version | type != "string" or length == 0) then
        error("state is missing terraform_version")
      elif (.serial | type != "number" or . < 0 or floor != .) then
        error("state serial must be a non-negative integer")
      elif (.lineage | type != "string" or length == 0) then
        error("state is missing lineage")
      elif (.resources | type != "array") or
           any(.resources[]; (.instances | type) != "array") then
        error("state resources must contain instance arrays")
      else
        {
          source: $source,
          state_format_version: .version,
          lineage: .lineage,
          serial: .serial,
          terraform_version: .terraform_version,
          resource_instance_count:
            (reduce (.resources[] | .instances[]) as $instance (0; . + 1))
        }
      end;
    metadata($source)
  '
}

bounded_stdin() {
  local data
  IFS= read -r -N "$((max_state_bytes + 1))" data || true
  ((${#data} <= max_state_bytes)) || fail "Terraform state exceeded 64 MiB"
  printf '%s' "$data"
}

live_metadata() {
  [[ -n "${TF_DIR:-}" ]] || fail "TF_DIR is required"
  (
    cd "$TF_DIR"
    "${TF_BIN:-terraform}" state pull
  ) | bounded_stdin | project_metadata live
}

candidate_path() {
  local filename=$1
  local root candidate size
  [[ -n "${TF_STATE_CANDIDATE_DIR:-}" ]] ||
    fail "TF_STATE_CANDIDATE_DIR is required"
  [[ "$filename" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,126}\.tfstate$ ]] ||
    fail "candidate file must be a bounded .tfstate basename"

  root=$(realpath -e -- "$TF_STATE_CANDIDATE_DIR") ||
    fail "candidate state directory does not exist"
  [[ "$root" != / ]] || fail "candidate state directory cannot be the filesystem root"
  candidate=$(realpath -e -- "$root/$filename") ||
    fail "candidate state file does not exist"
  [[ "$candidate" == "$root/"* ]] ||
    fail "candidate state file escapes the configured directory"
  [[ -f "$candidate" && -r "$candidate" ]] ||
    fail "candidate state file must be a readable regular file"
  size=$(stat -c %s -- "$candidate")
  ((size <= max_state_bytes)) || fail "candidate Terraform state exceeded 64 MiB"
  printf '%s\n' "$candidate"
}

file_metadata() {
  local filename=$1
  local candidate
  candidate=$(candidate_path "$filename")
  project_metadata candidate <"$candidate"
}

mode=${1:-}
case "$mode" in
  live)
    live_metadata
    ;;
  file)
    file_metadata "$2"
    ;;
  compare)
    filename=$2
    live=$(live_metadata)
    candidate=$(file_metadata "$filename")
    LIVE_METADATA=$live CANDIDATE_METADATA=$candidate jq -nce '
      (env.LIVE_METADATA | fromjson) as $live |
      (env.CANDIDATE_METADATA | fromjson) as $candidate |
      if $live.lineage != $candidate.lineage then
        {
          live: $live,
          candidate: $candidate,
          relation: "lineage_mismatch",
          serial_delta: null
        }
      else
        {
          live: $live,
          candidate: $candidate,
          relation:
            (if $candidate.serial < $live.serial then "candidate_older"
             elif $candidate.serial > $live.serial then "candidate_newer"
             else "equal_serial"
             end),
          serial_delta: ($candidate.serial - $live.serial)
        }
      end
    '
    ;;
  *)
    fail "unsupported Terraform state metadata operation"
    ;;
esac

#!/usr/bin/env bash
set -euo pipefail

project=${PROJECT_ID:-emisar}
apply=false
requested=""

if [[ ${1:-} == --apply ]]; then
  apply=true
  requested=${2:-}
  [[ $# -le 2 ]] || { echo "usage: $0 [--apply [DRILL_ID]]" >&2; exit 2; }
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--apply [DRILL_ID]]" >&2
  exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ids="$tmp/ids"
: >"$ids"

inventory() {
  sql_json=$(gcloud sql instances list --project "$project" --format=json) || return
  vm_json=$(gcloud compute instances list --project "$project" --format=json) || return
  sa_json=$(gcloud iam service-accounts list --project "$project" --format=json) || return
}

if [[ -n $requested ]]; then
  printf '%s\n' "$requested" >"$ids"
else
  inventory
  {
    jq -r '.[] |
      (.settings.userLabels.drill_id // empty),
      (.name | capture("^(?<id>edrill-[0-9]{10}-[0-9a-f]{6})-db$").id? // empty)' <<<"$sql_json"
    jq -r '.[] |
      (.labels.drill_id // empty),
      (.name | capture("^(?<id>edrill-[0-9]{10}-[0-9a-f]{6})-probe$").id? // empty)' <<<"$vm_json"
    jq -r '.[] | .email |
      capture("^(?<id>edrill-[0-9]{10}-[0-9a-f]{6})@.*$").id? // empty' <<<"$sa_json"
  } >>"$ids"
  LC_ALL=C sort -u -o "$ids" "$ids"
fi

to_epoch() {
  local compact=$1 formatted
  formatted="20${compact:0:2}-${compact:2:2}-${compact:4:2} ${compact:6:2}:${compact:8:2}:00"
  if date -u -d "$formatted" +%s >/dev/null 2>&1; then
    date -u -d "$formatted" +%s
  else
    date -j -u -f '%Y-%m-%d %H:%M:%S' "$formatted" +%s
  fi
}

now=$(date -u +%s)
failures=0
while IFS= read -r id; do
  [[ -z $id ]] && continue
  [[ $id =~ ^edrill-([0-9]{10})-([0-9a-f]{6})$ ]] || {
    echo "refusing unexpected drill id: ${id}" >&2
    failures=1
    continue
  }
  created=$(to_epoch "${BASH_REMATCH[1]}")
  age=$((now - created))
  if [[ -z $requested && $age -lt 43200 ]]; then
    echo "keeping active drill ${id} (age ${age}s; janitor threshold 43200s)"
    continue
  fi

  clone="${id}-db"
  vm="${id}-probe"
  service_account="${id}@${project}.iam.gserviceaccount.com"
  echo "cleanup candidate: ${id}"
  [[ $apply == true ]] || continue

  if ! inventory || ! project_policy=$(gcloud projects get-iam-policy "$project" --format=json); then
    echo "inventory failed for ${id}; refusing to infer absence" >&2
    failures=1
    continue
  fi

  sa=$(jq -c --arg email "$service_account" '[.[] | select(.email == $email)]' <<<"$sa_json")
  sa_count=$(jq 'length' <<<"$sa")
  if [[ $sa_count -gt 1 ]]; then
    echo "refusing ambiguous service-account inventory: ${service_account}" >&2
    failures=1
    continue
  fi
  sa_owned=false
  if [[ $sa_count -eq 1 ]]; then
    display_name=$(jq -r '.[0].displayName // ""' <<<"$sa")
    if [[ $display_name != "Temporary recovery drill ${id}" ]]; then
      echo "refusing service account with unexpected display name: ${service_account}" >&2
      failures=1
      continue
    fi
    sa_owned=true
  fi

  vm_rows=$(jq -r --arg name "$vm" '.[] | select(.name == $name) |
    [.zone | split("/")[-1], .labels.purpose // "", .labels.drill_id // ""] | @tsv' <<<"$vm_json")
  while IFS=$'\t' read -r zone purpose drill_id; do
    [[ -z $zone ]] && continue
    if [[ $purpose != recovery-drill || $drill_id != "$id" ]]; then
      echo "refusing VM with mismatched ownership labels: ${vm}" >&2
      failures=1
      continue
    fi
    gcloud compute instances delete "$vm" --project "$project" --zone "$zone" --quiet || failures=1
  done <<<"$vm_rows"

  condition="$tmp/${id}-condition.json"
  printf '{"title":"%s-only","description":"Temporary non-production recovery drill","expression":"resource.name == '\''projects/%s/instances/%s'\'' && resource.type == '\''sqladmin.googleapis.com/Instance'\''"}\n' \
    "$id" "$project" "$clone" >"$condition"
  for role in roles/cloudsql.client roles/cloudsql.instanceUser; do
    if jq -e --arg member "serviceAccount:${service_account}" --arg role "$role" \
      'any(.bindings[]?; .role == $role and any(.members[]?; . == $member))' \
      <<<"$project_policy" >/dev/null; then
      gcloud projects remove-iam-policy-binding "$project" \
        --member="serviceAccount:${service_account}" --role="$role" \
        --condition-from-file="$condition" --quiet || failures=1
    fi
  done

  sql=$(jq -c --arg name "$clone" '[.[] | select(.name == $name)]' <<<"$sql_json")
  sql_count=$(jq 'length' <<<"$sql")
  if [[ $sql_count -gt 1 ]]; then
    echo "refusing ambiguous SQL inventory: ${clone}" >&2
    failures=1
    continue
  fi
  if [[ $sql_count -eq 1 ]]; then
    purpose=$(jq -r '.[0].settings.userLabels.purpose // ""' <<<"$sql")
    drill_id=$(jq -r '.[0].settings.userLabels.drill_id // ""' <<<"$sql")
    if [[ $purpose == recovery-drill && $drill_id == "$id" ]]; then
      :
    elif [[ -z $purpose && -z $drill_id && $sa_owned == true ]]; then
      echo "recovering pre-label clone whose matching service account proves drill ownership: ${clone}"
    else
      echo "refusing SQL instance without exact ownership proof: ${clone}" >&2
      failures=1
      continue
    fi
    gcloud sql instances patch "$clone" --project "$project" --no-deletion-protection --quiet || failures=1
    gcloud sql instances delete "$clone" --project "$project" --quiet || failures=1
  fi

  if [[ $sa_owned == true ]]; then
    gcloud iam service-accounts delete "$service_account" --project "$project" --quiet || failures=1
  fi

  if ! inventory || ! project_policy=$(gcloud projects get-iam-policy "$project" --format=json); then
    echo "final inventory failed for ${id}; cleanup is unverified" >&2
    failures=1
    continue
  fi
  remaining_vm=$(jq -r --arg name "$vm" '.[] | select(.name == $name) | .name' <<<"$vm_json")
  remaining_sql=$(jq -r --arg name "$clone" '.[] | select(.name == $name) | .name' <<<"$sql_json")
  remaining_sa=$(jq -r --arg email "$service_account" '.[] | select(.email == $email) | .email' <<<"$sa_json")
  remaining_iam=$(jq -r --arg member "serviceAccount:${service_account}" \
    '.bindings[]? | select(any(.members[]?; . == $member)) | .role' <<<"$project_policy")
  if [[ -n $remaining_vm || -n $remaining_sql || -n $remaining_sa || -n $remaining_iam ]]; then
    echo "cleanup verification failed for ${id}" >&2
    failures=1
  else
    echo "cleanup verified: ${id} has no VM, SQL instance, service account, or IAM binding"
  fi
done <"$ids"

exit "$failures"

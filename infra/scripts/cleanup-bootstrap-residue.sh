#!/usr/bin/env bash
set -euo pipefail

project=${PROJECT_ID:-emisar}
project_number=${PROJECT_NUMBER:-$(gcloud projects describe "$project" --format='value(projectNumber)')}
[[ $project_number =~ ^[0-9]+$ ]] || { echo "could not resolve project number" >&2; exit 1; }
default_sa="${project_number}-compute@developer.gserviceaccount.com"
legacy_state_bucket=${LEGACY_STATE_BUCKET:-emisar-tfstate}
apply=false

if [[ ${1:-} == --apply ]]; then
  apply=true
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--apply]" >&2
  exit 2
fi

read_inventory() {
  instances_json=$(gcloud compute instances list --project "$project" --format=json) || return
  networks_json=$(gcloud compute networks list --project "$project" --format=json) || return
  firewalls_json=$(gcloud compute firewall-rules list --project "$project" --format=json) || return
  project_policy=$(gcloud projects get-iam-policy "$project" --format=json) || return
  buckets_json=$(gcloud storage buckets list --project "$project" --format=json) || return
}

read_inventory
instances_on_default=$(jq -r '.[] | select(any(.networkInterfaces[]?; (.network | split("/")[-1]) == "default")) | .name' <<<"$instances_json")
instances_using_default_sa=$(jq -r --arg email "$default_sa" \
  '.[] | select(any(.serviceAccounts[]?; .email == $email)) | .name' <<<"$instances_json")

if [[ -n $instances_on_default || -n $instances_using_default_sa ]]; then
  echo "refusing cleanup: a VM still uses the default network or service account" >&2
  printf '%s\n' "$instances_on_default" "$instances_using_default_sa" >&2
  exit 1
fi

echo "verified: no VM uses the default network or ${default_sa}"
jq -r '.[] | select((.network | split("/")[-1]) == "default") |
  [.name, .direction, (.sourceRanges // [] | join(","))] | @tsv' <<<"$firewalls_json"
jq -r --arg member "serviceAccount:${default_sa}" '.bindings[]? |
  select(.role == "roles/editor" and any(.members[]?; . == $member)) |
  [.role, $member] | @tsv' <<<"$project_policy"

bucket_present=$(jq -r --arg name "$legacy_state_bucket" 'any(.[]; .name == $name)' <<<"$buckets_json")
if [[ $bucket_present == true ]]; then
  legacy_objects=$(gcloud storage ls --recursive "gs://${legacy_state_bucket}/**")
  printf '%s\n' "$legacy_objects"
else
  echo "legacy state bucket is already absent"
fi

if [[ $apply != true ]]; then
  echo "dry run only; archive the legacy state evidence, then rerun with --apply"
  exit 0
fi

if [[ ${CONFIRM_LEGACY_STATE_ARCHIVED:-} != yes ]]; then
  echo "set CONFIRM_LEGACY_STATE_ARCHIVED=yes after preserving required evidence" >&2
  exit 1
fi

while IFS= read -r rule; do
  [[ -z $rule ]] || gcloud compute firewall-rules delete "$rule" --project "$project" --quiet
done < <(jq -r '.[] | select((.network | split("/")[-1]) == "default") | .name' <<<"$firewalls_json")

if jq -e 'any(.[]; .name == "default")' <<<"$networks_json" >/dev/null; then
  gcloud compute networks delete default --project "$project" --quiet
fi
if jq -e --arg member "serviceAccount:${default_sa}" '
  any(.bindings[]?; .role == "roles/editor" and any(.members[]?; . == $member))
' <<<"$project_policy" >/dev/null; then
  gcloud projects remove-iam-policy-binding "$project" \
    --member="serviceAccount:${default_sa}" --role=roles/editor \
    --condition=None --quiet
fi
if [[ $bucket_present == true ]]; then
  legacy_objects=$(gcloud storage ls --recursive "gs://${legacy_state_bucket}/**")
  if [[ -n $legacy_objects ]]; then
    gcloud storage rm --recursive "gs://${legacy_state_bucket}/**"
  fi
  gcloud storage buckets delete "gs://${legacy_state_bucket}" --quiet
fi

read_inventory
network_remaining=$(jq -r 'any(.[]; .name == "default")' <<<"$networks_json")
editor_remaining=$(jq -r --arg member "serviceAccount:${default_sa}" '
  any(.bindings[]?; .role == "roles/editor" and any(.members[]?; . == $member))
' <<<"$project_policy")
bucket_remaining=$(jq -r --arg name "$legacy_state_bucket" 'any(.[]; .name == $name)' <<<"$buckets_json")
if [[ $network_remaining == true || $editor_remaining == true || $bucket_remaining == true ]]; then
  echo "bootstrap residue cleanup verification failed" >&2
  exit 1
fi

echo "verified: default network, default-SA Editor grant, and legacy state bucket are absent"

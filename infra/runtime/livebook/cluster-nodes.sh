#!/bin/bash
set -euo pipefail

token_response=$(wget --quiet --timeout=30 --tries=5 --waitretry=2 \
  --header="Metadata-Flavor: Google" -O - \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token)
token=$(printf '%s' "$token_response" | grep -oE '"access_token": ?"[^"]+"' | cut -d'"' -f4 || true)
[ -n "$token" ] || { echo "No metadata access token" >&2; exit 1; }

body=$(mktemp)
trap 'rm -f "$body"' EXIT
url="https://compute.googleapis.com/compute/v1/projects/${project_id}/aggregated/instances?filter=labels.cluster_name%3Demisar%20AND%20status%3DRUNNING"
wget --quiet --timeout=30 --tries=5 --waitretry=2 \
  --header="Authorization: Bearer $token" -O "$body" "$url" || {
  echo "Compute API cluster discovery failed" >&2
  exit 1
}

ips=$(grep -oE '"networkIP": ?"[^"]+"' "$body" | cut -d'"' -f4 | sort -u || true)
[ -n "$ips" ] || { echo "No running portal nodes found" >&2; exit 1; }
while IFS= read -r ip; do
  printf 'emisar@%s\n' "$ip"
done <<<"$ips"

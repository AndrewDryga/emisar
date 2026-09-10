#!/bin/bash
# The health barrier both backend services wait on (load_balancer.tf, rule 9):
# the URL map switches only after backendServices.getHealth reports every
# expected VM healthy. Not templated — the caller passes EXPECTED_INSTANCES
# (1 for the single Livebook VM), so the two barriers cannot drift apart the
# way the previous hand-written pair did.
set -euo pipefail

for tool in curl grep mktemp seq sleep tr wc; do
  command -v "$tool" >/dev/null || {
    echo "backend readiness check requires $tool" >&2
    exit 1
  }
done

url="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/global/backendServices/$BACKEND_SERVICE/getHealth"
payload=$(printf '{"group":"%s"}' "$INSTANCE_GROUP")
response_file=$(mktemp)
trap 'rm -f "$response_file"' EXIT

for attempt in $(seq 1 60); do
  if ! status=$(curl --silent --show-error \
    --connect-timeout 5 --max-time 30 --output "$response_file" \
    --write-out '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "$url"); then
    echo "backend health request failed on attempt $attempt" >&2
    exit 1
  fi

  case "$status" in
    200) ;;
    429 | 5??)
      sleep 10
      continue
      ;;
    401 | 403)
      echo "backend health authentication was rejected with HTTP $status" >&2
      exit 1
      ;;
    *)
      echo "backend health request returned unexpected HTTP $status" >&2
      exit 1
      ;;
  esac

  healthy=$(tr -d '[:space:]' < "$response_file" |
    grep -o '"healthState":"HEALTHY"' | wc -l | tr -d ' ') || healthy=0

  if [ "$healthy" -ge "$EXPECTED_INSTANCES" ]; then
    exit 0
  fi

  sleep 10
done

echo "backend $BACKEND_SERVICE did not reach $EXPECTED_INSTANCES healthy instances" >&2
exit 1

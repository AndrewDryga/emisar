#!/bin/bash
set -euo pipefail

# A service restart must not turn a registry or NAT incident into a local outage.
# New digests still pull on first boot; already verified local digests run.
ensure_image() {
  local image=$1
  local attempt

  docker image inspect "$image" >/dev/null 2>&1 && return

  for attempt in 1 2 3 4 5; do
    docker pull "$image" && return
    [ "$attempt" -eq 5 ] || sleep "$((attempt * 2))"
  done

  return 1
}

ensure_image "${livebook_image}"
ensure_image "${cloud_sql_proxy_image}"

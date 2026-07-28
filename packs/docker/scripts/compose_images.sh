#!/bin/bash
set -euo pipefail

file=$1
readonly max_output_bytes=524288

images=$(docker compose -f "$file" images --format json |
  head -c "$((max_output_bytes + 1))")
((${#images} <= max_output_bytes)) || {
  printf '%s\n' "Compose image inventory exceeded 512 KiB" >&2
  exit 1
}

if [[ -z "$images" ]]; then
  printf '[]\n'
else
  jq -ce '
    if . == null then []
    elif type == "array" then .
    else error("unexpected Compose image output")
    end
  ' \
    <<<"$images"
fi

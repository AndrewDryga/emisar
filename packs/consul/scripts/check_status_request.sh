#!/bin/sh
# Health reads promise check status, not whatever a check printed. Drop every
# check's Output (arbitrary application text) before the result reaches the
# model or the audit trail. The body is captured first, so a failed request
# keeps its exit status instead of becoming jq's empty input.
set -eu

body=$(sh "$(dirname "$0")/api_request.sh" GET "$1")
printf '%s\n' "$body" | jq -c '
  def without_output:
    if type == "object" then del(.Output) | map_values(without_output)
    elif type == "array" then map(without_output)
    else . end;
  without_output'

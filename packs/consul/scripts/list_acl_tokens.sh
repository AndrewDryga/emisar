#!/bin/sh
set -eu
umask 077

response=$(mktemp)
trap 'rm -f "$response"' EXIT HUP INT TERM

# Never replay the CLI's secret-bearing stdout, even when it exits nonzero
# after writing an otherwise valid JSON response.
status=0
consul acl token list -format=json >"$response" || status=$?
[ "$status" -eq 0 ] || exit "$status"

jq -ce '
  if type != "array" then error("expected ACL token array")
  else map({AccessorID, Description, Policies: [.Policies[]?.Name], Local})
  end
' "$response"

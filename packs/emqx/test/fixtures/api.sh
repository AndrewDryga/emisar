#!/bin/sh
# Test-only EMQX REST call for arrange and probe steps, independent of the
# pack script under test: api.sh METHOD PATH [JSON-BODY]. A rejected call
# prints EMQX's error body and exits 22, so a probe can assert NOT_FOUND.
set -eu
method=$1
path=$2
if [ "$#" -gt 2 ]; then
  set -- -H 'Content-Type: application/json' --data-binary "$3"
else
  set --
fi
exec curl -sS --fail-with-body --globoff -u "$EMQX_API_KEY:$EMQX_API_SECRET" \
  -X "$method" "$@" "$EMQX_URL/api/v5/$path"

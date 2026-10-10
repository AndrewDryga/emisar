#!/bin/sh
set -eu

# Require genuine second pages, not a fixture below the API's default100.
for kind in services routers; do
  first=$(curl -fsS "http://127.0.0.1:8080/api/http/$kind?page=1") || exit $?
  second=$(curl -fsS "http://127.0.0.1:8080/api/http/$kind?page=2") || exit $?
  printf '%s' "$first" | jq -e '
    length == 100 and all(.[]; (.name | startswith("zz-late-")) | not)
  ' >/dev/null
  printf '%s' "$second" | jq -e '
    any(.[]; .name == "zz-late-healthy@file")
    and any(.[]; .name == "zz-late-down@file")
  ' >/dev/null
done

# Both sentinels must have actual runtime health, not only declared URLs.
services=$(curl -fsS "http://127.0.0.1:8080/api/http/services?page=2") || exit $?
printf '%s' "$services" | jq -e '
  any(.[]; .name == "zz-late-healthy@file"
    and .serverStatus["http://127.0.0.1:8082"] == "UP")
  and any(.[]; .name == "zz-late-down@file"
    and .serverStatus["http://127.0.0.1:9999"] == "DOWN")
' >/dev/null

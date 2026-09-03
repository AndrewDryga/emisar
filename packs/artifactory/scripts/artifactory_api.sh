#!/bin/sh
# One request path for every Artifactory action.
#
# The credential rides a curl config document on stdin, never argv, so it
# stays out of /proc/<pid>/cmdline. ARTIFACTORY_URL is operator-set, so the
# transfer is pinned to http/https and globbing is off — a {a,b} in a URL
# segment would otherwise expand into one transfer per alternative.
#
# ARTIFACTORY_URL is the JFrog platform base (scheme + host + port, no
# trailing path): the script appends /artifactory/api/... itself, the layout
# both a self-hosted platform router (:8082) and *.jfrog.io serve.
set -eu

mode=$1

api_base=${ARTIFACTORY_URL:-http://127.0.0.1:8082}
api_base=${api_base%/}

case "$api_base" in
  http://* | https://*) ;;
  *)
    printf '%s\n' "ARTIFACTORY_URL must be an http:// or https:// URL" >&2
    exit 2
    ;;
esac

art_api="$api_base/artifactory/api"

# curl collapses /../ before sending, so a dotted segment in a repository key
# or artifact path would climb out of the storage API into an arbitrary
# endpoint on the same host. The arg patterns do NOT exclude it — `.` and `/`
# are both members of their character class — so this guard is the containment,
# not a second layer. Same guard, same reason, in dell-idrac's idracreq.sh.
reject_dotdot() {
  case "$1" in
    *..*)
      printf '%s\n' "repository and artifact paths must not contain '..'" >&2
      exit 2
      ;;
  esac
}

# Basic auth when a user is set, otherwise the access token. Both are written
# as curl config directives so neither reaches the process table.
auth_config() {
  if [ -n "${ARTIFACTORY_USER:-}" ]; then
    printf 'user = "%s:%s"\n' "$ARTIFACTORY_USER" "${ARTIFACTORY_PASSWORD:-}"
  else
    printf 'header = "Authorization: Bearer %s"\n' "${ARTIFACTORY_TOKEN:-}"
  fi
}

request() {
  auth_config | curl -q --config - --fail --silent --show-error --globoff \
    --proto '=http,https' --connect-timeout 10 --max-time 60 \
    --max-filesize 4194304 "$@"
}

case "$mode" in
  license) request "$art_api/system/license" ;;
  ping) request "$art_api/system/ping" ;;
  storage-summary) request "$art_api/storageinfo" ;;
  tasks) request "$art_api/tasks" ;;
  version) request "$art_api/system/version" ;;

  # --get + --data-urlencode so filter values are encoded by curl rather than
  # pasted into the query string.
  repositories)
    type_filter=${2:-}
    package_filter=${3:-}
    set --
    if [ -n "$type_filter" ]; then
      set -- "$@" --data-urlencode "type=$type_filter"
    fi
    if [ -n "$package_filter" ]; then
      set -- "$@" --data-urlencode "packageType=$package_filter"
    fi
    request --get "$@" "$art_api/repositories"
    ;;

  file-info)
    reject_dotdot "$2/$3"
    request "$art_api/storage/$2/$3"
    ;;

  file-stats)
    reject_dotdot "$2/$3"
    request "$art_api/storage/$2/$3?stats"
    ;;

  *)
    printf '%s\n' "unsupported Artifactory operation: $mode" >&2
    exit 2
    ;;
esac

#!/bin/sh
# One request path for every SuperTokens core action.
#
# The core API key rides a curl config document on stdin, never argv, so it
# stays out of /proc/<pid>/cmdline. SUPERTOKENS_URL is operator-set, so the
# transfer is pinned to http/https and globbing is off.
set -eu

mode=$1

api_base=${SUPERTOKENS_URL:-http://127.0.0.1:3567}
api_base=${api_base%/}

case "$api_base" in
  http://* | https://*) ;;
  *)
    printf '%s\n' "SUPERTOKENS_URL must be an http:// or https:// URL" >&2
    exit 2
    ;;
esac

# A core without an api_keys setting accepts unauthenticated calls, so the
# header is sent only when a key is set.
auth_config() {
  if [ -n "${SUPERTOKENS_API_KEY:-}" ]; then
    printf 'header = "api-key: %s"\n' "$SUPERTOKENS_API_KEY"
  fi
}

request() {
  # --fail-with-body: a rejected key comes back as "Invalid API key", which is
  # the whole diagnosis.
  auth_config | curl -q --config - --fail-with-body --silent --show-error --globoff \
    --proto '=http,https' --connect-timeout 10 --max-time 20 \
    --max-filesize 4194304 "$@"
}

case "$mode" in
  hello) request "$api_base/hello" ;;
  api-version) request "$api_base/apiversion" ;;
  user-count) request "$api_base/users/count?includeAllTenants=true" ;;
  active-users)
    since=$(( ($(date +%s) - $2 * 60) * 1000 ))
    request "$api_base/users/count/active?since=$since"
    ;;
  # The tenant list carries third-party client secrets and raw core config
  # overrides (database settings among them). Captured, not piped, so a failed
  # request reports its own error instead of an empty projection; then only
  # ids, login methods, provider names and override keys leave the host.
  tenants)
    rc=0
    response=$(request "$api_base/recipe/multitenancy/tenant/list/v2") || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ -n "$response" ]; then
        printf '%s\n' "$response" >&2
      fi
      exit "$rc"
    fi
    printf '%s' "$response" | jq -ce '{tenants: [.tenants[] | {
      tenant_id: .tenantId,
      first_factors: .firstFactors,
      required_secondary_factors: .requiredSecondaryFactors,
      third_party_providers: [(.thirdParty.providers // [])[] | .thirdPartyId],
      core_config_overrides: ((.coreConfig // {}) | keys)
    }]}'
    ;;
  *)
    printf '%s\n' "unsupported SuperTokens operation: $mode" >&2
    exit 2
    ;;
esac

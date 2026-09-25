#!/bin/sh
# One request path for every SuperTokens core action.
#
# The core API key and every query value ride a curl config document on stdin,
# never argv, so neither the key nor a searched email reaches
# /proc/<pid>/cmdline. SUPERTOKENS_URL is operator-set, so the transfer is
# pinned to http/https and globbing is off. JSON bodies are built with jq
# --arg, so no argument can change the request's path, add a parameter, or
# end a JSON string early.
set -eu

mode=$1
shift

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

# A value written into a quoted curl config string must not end it early.
# The action patterns already refuse these characters; this is the backstop.
config_safe() {
  case "$1" in
    *'"'* | *'\'* | *'
'*)
      printf '%s\n' "value must not contain a quote, backslash or newline" >&2
      exit 2
      ;;
  esac
}

curl_core() {
  # --fail-with-body: the core answers a rejection with a plain-text reason
  # ("Invalid API key", "Field name ... is missing in GET request"), which is
  # the whole diagnosis.
  curl -q --config - --fail-with-body --silent --show-error --globoff \
    --proto '=http,https' --connect-timeout 10 --max-time 20 \
    --max-filesize 4194304 "$@"
}

# GET $1 with each "name=value" after it as a query parameter; a pair with an
# empty value is left out, so an unset filter matches everything.
get() {
  path=$1
  shift
  for pair in "$@"; do
    config_safe "$pair"
  done
  {
    auth_config
    for pair in "$@"; do
      if [ -n "${pair#*=}" ]; then
        printf 'data-urlencode = "%s"\n' "$pair"
      fi
    done
  } | curl_core --get "$api_base/$path"
}

# send METHOD PATH JSON
send() {
  auth_config | curl_core -X "$1" -H 'Content-Type: application/json' \
    --data-binary "$3" "$api_base/$2"
}

# The core answers "not found" and "unknown role" as HTTP 200 with a status
# other than OK, so a captured answer fails on that status too; otherwise a
# typo'd id would read as a successful, empty result.
checked() {
  if [ "$rc" -ne 0 ]; then
    if [ -n "$response" ]; then
      printf '%s\n' "$response"
    fi
    exit "$rc"
  fi
  status=$(printf '%s' "$response" | jq -r 'if type == "object" then (.status // "OK") else "OK" end' 2>/dev/null) || {
    printf '%s\n' "the core did not answer with JSON" >&2
    exit 1
  }
  if [ "$status" != OK ]; then
    printf '%s\n' "$response"
    printf 'the core answered %s\n' "$status" >&2
    exit 1
  fi
}

fetch() {
  rc=0
  response=$(get "$@") || rc=$?
  checked
}

submit() {
  rc=0
  response=$(send "$@") || rc=$?
  checked
}

# The core accepts a write for a user id it does not know and answers OK, so
# every write looks the user up first. .user.id is the external id when one is
# mapped, which is the id the app's SDK reads roles and sessions under.
resolve_user() {
  fetch user/id "userId=$1"
  user=$response
  user_id=$(printf '%s' "$user" | jq -r .user.id)
}

project() {
  printf '%s' "$response" | jq -c "$@"
}

millis_to_iso='def iso: if . == null then null else (. / 1000 | floor | todate) end;'

case "$mode" in
  hello)
    auth_config | curl_core "$api_base/hello"
    ;;
  api-version)
    fetch apiversion
    project '(.versions | sort_by(split(".") | map(tonumber))) as $v |
      {latest: $v[-1], versions: $v}'
    ;;
  request-stats)
    fetch requests/stats
    project 'def window($n): {
        avg_rps: ([.averageRequestsPerSecond[-$n:][] | select(. >= 0)] |
          if length == 0 then null else (add / length * 1000 | round / 1000) end),
        peak_rps: ([.peakRequestsPerSecond[-$n:][] | select(. >= 0)] | max)
      };
      {minutes_with_data: ([.averageRequestsPerSecond[] | select(. >= 0)] | length),
       last_1m: window(1), last_5m: window(5), last_60m: window(60),
       last_24h: window(1440)}'
    ;;
  usage-stats)
    fetch ee/featureflag
    project '(.usageStats // {}) as $u | {
      features: .features,
      active_last_1d: $u.maus[0], active_last_7d: $u.maus[6],
      active_last_30d: $u.maus[29], active_by_days: $u.maus,
      feature_stats: ($u | del(.maus))}'
    ;;
  config)
    fetch recipe/dashboard/tenant/core-config
    # A closed allowlist: a key the list does not name, including any secret a
    # future core adds, leaves the host by name only. Settings are name/value
    # rows because the values sit under names like access_token_validity that
    # the runner's secret-field redaction would otherwise mask.
    project '{
      "access_token_validity": true, "access_token_validity_jitter": true,
      "access_token_dynamic_signing_key_update_interval": true,
      "refresh_token_validity": true, "refresh_token_rotation_grace_period": true,
      "password_reset_token_lifetime": true,
      "email_verification_token_lifetime": true,
      "passwordless_code_lifetime": true,
      "passwordless_max_code_input_attempts": true,
      "totp_max_attempts": true, "totp_rate_limit_cooldown_sec": true,
      "webauthn_recover_account_token_lifetime": true,
      "password_hashing_alg": true, "disable_telemetry": true,
      "ip_allow_regex": true, "ip_deny_regex": true,
      "postgresql_host": true, "postgresql_port": true,
      "postgresql_database_name": true, "postgresql_table_schema": true,
      "postgresql_table_names_prefix": true,
      "postgresql_connection_pool_size": true,
      "postgresql_idle_connection_timeout": true,
      "postgresql_minimum_idle_connections": true, "migration_mode": true
    } as $allow | [.config[]] as $c | {
      settings: [$c[] | select($allow[.key]) | {name: .key, value: .value}] | sort_by(.name),
      non_default: ([$c[] | select(.value != .defaultValue) | .key] | sort),
      withheld: ([$c[] | select($allow[.key] | not) | .key] | sort)}'
    ;;
  tenants)
    fetch recipe/multitenancy/tenant/list/v2
    # The raw list carries each provider's client secrets, private keys and
    # token-endpoint parameters, and raw core config overrides (tenant database
    # passwords among them); only ids, names, public client ids and the names
    # of the overrides leave the host.
    project '{tenants: [.tenants[] | {
      tenant_id: .tenantId,
      first_factors: .firstFactors,
      required_secondary_factors: .requiredSecondaryFactors,
      third_party_providers: [(.thirdParty.providers // [])[] | {
        third_party_id: .thirdPartyId, name: .name,
        clients: [(.clients // [])[] | {client_type: .clientType,
          client_id: .clientId, scope: .scope,
          confidential: ((.clientSecret // "") != "")}]}],
      core_config_overrides: ((.coreConfig // {}) | keys)}]}'
    ;;
  migration-status)
    fetch migration/backfill/progress
    project '{connection_uri_domains: (if has("cuds") then
      [.cuds[] | {connection_uri_domain: .connectionUriDomain, mode: .mode,
        pending_users: .pendingUsers}]
      else [{connection_uri_domain: null, mode: .mode, pending_users: .pendingUsers}] end)}'
    ;;
  user-count)
    recipe=$1
    [ "$recipe" != all ] || recipe=
    fetch users/count includeAllTenants=true "includeRecipeIds=$recipe"
    project '{count: .count}'
    ;;
  active-users)
    since=$(( ($(date +%s) - $1 * 60) * 1000 ))
    fetch users/count/active "since=$since"
    project '{count: .count}'
    ;;
  user)
    fetch user/id "userId=$1"
    project '.user'
    ;;
  find-user)
    # Exactly one lookup, by email, phone, or third-party identity; the values
    # arrive through the environment because they are customer PII.
    email=${ARG_EMAIL:-}
    phone=${ARG_PHONE:-}
    tp_id=${ARG_THIRD_PARTY_ID:-}
    tp_user=${ARG_THIRD_PARTY_USER_ID:-}
    lookups=0
    [ -z "$email" ] || lookups=$((lookups + 1))
    [ -z "$phone" ] || lookups=$((lookups + 1))
    [ -z "$tp_id$tp_user" ] || lookups=$((lookups + 1))
    if [ "$lookups" -ne 1 ] || { [ -n "$tp_id$tp_user" ] && { [ -z "$tp_id" ] || [ -z "$tp_user" ]; }; }; then
      printf '%s\n' "set exactly one of email, phone, or third_party_id with third_party_user_id" >&2
      exit 2
    fi
    fetch users/by-accountinfo doUnionOfAccountInfo=false "email=$email" \
      "phoneNumber=$phone" "thirdPartyId=$tp_id" "thirdPartyUserId=$tp_user"
    project '{count: (.users | length), users: .users}'
    ;;
  users)
    order=DESC
    [ "$1" != oldest ] || order=ASC
    recipe=$3
    [ "$recipe" != all ] || recipe=
    fetch users "timeJoinedOrder=$order" "limit=$2" "includeRecipeIds=$recipe" \
      "provider=$4" "paginationToken=$5" "email=${ARG_EMAIL_SEARCH:-}"
    project '{count: (.users | length), users: .users,
      next_page_cursor: .nextPaginationToken}'
    ;;
  user-sessions)
    resolve_user "$1"
    limit=$2
    fetch recipe/session/user "userId=$user_id" fetchAcrossAllTenants=true \
      fetchSessionsForAllLinkedAccounts=true
    handles=$(project -r '.sessionHandles[]')
    total=$(project '.sessionHandles | length')
    sessions=
    count=0
    while IFS= read -r handle; do
      [ -n "$handle" ] || continue
      [ "$count" -lt "$limit" ] || break
      count=$((count + 1))
      rc=0
      one=$(get recipe/session "sessionHandle=$handle") || rc=$?
      if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$one"
        exit "$rc"
      fi
      # A session that expires between the list and this read answers
      # UNAUTHORISED; it is simply no longer a session. The access-token
      # payload and the session data are app-defined and can hold PII or
      # third-party tokens, so only their key names leave the host, plus the
      # values of the SuperTokens-owned role, permission, email-verification
      # and MFA claims.
      one=$(printf '%s' "$one" | jq -c "$millis_to_iso"'
        select(.status == "OK") | {
          handle: .sessionHandle, tenant_id: .tenantId, user_id: .userId,
          recipe_user_id: .recipeUserId,
          created: (.timeCreated | iso), refresh_expires: (.expiry | iso),
          claims: ((.userDataInJWT // {}) | with_entries(select(.key == "st-role"
            or .key == "st-perm" or .key == "st-ev" or .key == "st-mfa"))),
          payload_keys: ((.userDataInJWT // {}) | keys),
          session_data_keys: ((.userDataInDatabase // {}) | keys)}')
      sessions="$sessions$one
"
    done <<EOF
$handles
EOF
    printf '%s' "$sessions" | jq -sc --arg user_id "$user_id" --argjson total "$total" \
      --argjson limit "$limit" \
      '{user_id: $user_id, session_count: $total, sessions: .,
        truncated: ($total > $limit)}'
    ;;
  roles)
    fetch recipe/roles
    roles=$(project -r '.roles[]')
    total=$(project '.roles | length')
    out=
    count=0
    while IFS= read -r role; do
      [ -n "$role" ] || continue
      [ "$count" -lt 200 ] || break
      count=$((count + 1))
      rc=0
      perms=$(get recipe/role/permissions "role=$role") || rc=$?
      if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$perms"
        exit "$rc"
      fi
      # A role deleted between the two reads answers UNKNOWN_ROLE_ERROR.
      out="$out$(printf '%s' "$perms" | jq -c --arg role "$role" \
        '{role: $role, permissions: (if .status == "OK" then .permissions else null end)}')
"
    done <<EOF
$roles
EOF
    printf '%s' "$out" | jq -sc --argjson total "$total" \
      '{count: $total, roles: ., truncated: ($total > 200)}'
    ;;
  user-roles)
    resolve_user "$1"
    fetch recipe/user/roles "userId=$user_id"
    roles=$(project -r '.roles[]')
    user_roles=$(project '.roles')
    perms=
    while IFS= read -r role; do
      [ -n "$role" ] || continue
      rc=0
      one=$(get recipe/role/permissions "role=$role") || rc=$?
      if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$one"
        exit "$rc"
      fi
      perms="$perms$(printf '%s' "$one" | jq -c '.permissions // []')
"
    done <<EOF
$roles
EOF
    printf '%s' "$perms" | jq -sc --arg user_id "$user_id" --argjson roles "$user_roles" \
      '{user_id: $user_id, roles: $roles, permissions: (add // [] | unique)}'
    ;;
  role-users)
    fetch recipe/role/users "role=$1"
    project --arg role "$1" --argjson limit "$2" \
      '{role: $role, count: (.users | length), user_ids: .users[:$limit],
        truncated: ((.users | length) > $limit)}'
    ;;
  dashboard-users)
    fetch recipe/dashboard/users
    project "$millis_to_iso"'{count: (.users | length), users: [.users[] |
      {user_id: .userId, email: .email, time_joined: (.timeJoined | iso)}]}'
    ;;
  revoke-user-sessions)
    resolve_user "$1"
    submit POST recipe/session/remove "$(jq -nc --arg u "$user_id" \
      '{userId: $u, revokeAcrossAllTenants: true, revokeSessionsForLinkedAccounts: true}')"
    project --arg user_id "$user_id" '{user_id: $user_id,
      revoked_count: (.sessionHandlesRevoked | length),
      revoked_handles: .sessionHandlesRevoked}'
    ;;
  revoke-session)
    submit POST recipe/session/remove "$(jq -nc --arg h "$1" '{sessionHandles: [$h]}')"
    # The core answers OK for a handle that is already revoked or expired.
    if [ "$(project '.sessionHandlesRevoked | length')" -eq 0 ]; then
      printf '%s\n' "no live session has this handle; it is already revoked or expired" >&2
      exit 1
    fi
    project '{revoked_handles: .sessionHandlesRevoked}'
    ;;
  add-user-role)
    resolve_user "$1"
    submit PUT recipe/user/role "$(jq -nc --arg u "$user_id" --arg r "$2" '{userId: $u, role: $r}')"
    project --arg user_id "$user_id" --arg role "$2" \
      '{user_id: $user_id, role: $role, already_had_role: .didUserAlreadyHaveRole}'
    ;;
  remove-user-role)
    resolve_user "$1"
    submit POST recipe/user/role/remove "$(jq -nc --arg u "$user_id" --arg r "$2" '{userId: $u, role: $r}')"
    project --arg user_id "$user_id" --arg role "$2" \
      '{user_id: $user_id, role: $role, had_role: .didUserHaveRole}'
    ;;
  delete-user)
    resolve_user "$1"
    before=$(printf '%s' "$user" | jq '.user.loginMethods | length')
    submit POST user/remove "$(jq -nc --arg u "$user_id" --argjson all "$2" \
      '{userId: $u, removeAllLinkedAccounts: $all}')"
    # Read back: without all_linked_accounts, a primary user's other login
    # methods remain and the user still exists.
    rc=0
    after=$(get user/id "userId=$user_id") || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$after"
      exit "$rc"
    fi
    printf '%s' "$after" | jq -c --arg user_id "$user_id" --argjson before "$before" \
      '(if .status == "OK" then (.user.loginMethods | length) else 0 end) as $left |
       {user_id: $user_id, deleted: ($left == 0),
        login_methods_removed: ($before - $left)}'
    ;;
  signing-keys)
    fetch .well-known/jwks.json
    project "$millis_to_iso"'{keys: [.keys[] | {kid: .kid, alg: .alg, kty: .kty,
      use: .use, dynamic: (.kid | startswith("d-")),
      created: (if (.kid | test("^d-[0-9]+$")) then (.kid[2:] | tonumber | iso) else null end)}]}'
    ;;
  passwordless-codes)
    email=${ARG_EMAIL:-}
    phone=${ARG_PHONE:-}
    if { [ -n "$email" ] && [ -n "$phone" ]; } || { [ -z "$email" ] && [ -z "$phone" ]; }; then
      printf '%s\n' "set exactly one of email or phone" >&2
      exit 2
    fi
    fetch recipe/signinup/codes "email=$email" "phoneNumber=$phone"
    # Pre-auth session ids and code ids are dropped; the core never returns
    # the code or magic link here.
    project "$millis_to_iso"'{device_count: (.devices | length), devices: [.devices[] | {
      failed_code_input_attempts: .failedCodeInputAttemptCount,
      codes: [.codes[] | {created: (.timeCreated | iso),
        expires: ((.timeCreated + .codeLifetime) | iso)}]}]}'
    ;;
  *)
    printf '%s\n' "unsupported SuperTokens operation: $mode" >&2
    exit 2
    ;;
esac

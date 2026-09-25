#!/bin/sh
# Test-only SuperTokens core calls for arrange, resolve and probe steps,
# independent of the pack script under test.
#
#   core.sh call METHOD PATH [JSON]  one request; a rejected call prints the
#                                    core's reason and exits 22
#   core.sh seed                     the standard dataset below
#   core.sh id EMAIL                 the user id of an email address
#   core.sh session EMAIL            a new session for the user; prints its handle
#   core.sh sessions EMAIL           the user's session handles
#   core.sh roles EMAIL              the user's roles
set -eu

call() {
  method=$1
  path=$2
  if [ "$#" -gt 2 ]; then
    set -- -H 'Content-Type: application/json' --data-binary "$3"
  else
    set --
  fi
  curl -sS --fail-with-body --globoff -H "api-key: $SUPERTOKENS_API_KEY" \
    -X "$method" "$@" "$SUPERTOKENS_URL/$path"
}

id() {
  call GET "users/by-accountinfo?email=$1&doUnionOfAccountInfo=false" | jq -er '.users[0].id'
}

session() {
  call POST recipe/session "$(jq -nc --arg u "$(id "$1")" \
    '{userId: $u, userDataInJWT: {}, userDataInDatabase: {}, enableAntiCsrf: false}')" |
    jq -er .session.handle
}

command=$1
shift
case "$command" in
  call) call "$@" ;;
  id) id "$1" ;;
  session) session "$1" ;;
  sessions) call GET "recipe/session/user?userId=$(id "$1")" | jq -c .sessionHandles ;;
  roles) call GET "recipe/user/roles?userId=$(id "$1")" | jq -c .roles ;;
  seed)
    # Two email/password users, one Google sign-in, two roles with admin
    # granted to alice, a session for alice whose token and session data carry
    # app-defined values, a dashboard admin, a pending passwordless code, and
    # a Google provider with a client secret. Every secret is a canary the
    # cases assert never leaves the host.
    call POST recipe/signup '{"email":"alice@example.com","password":"packtest-Passw0rd"}' >/dev/null
    call POST recipe/signup '{"email":"bob@example.com","password":"packtest-Passw0rd"}' >/dev/null
    call POST recipe/signinup '{"thirdPartyId":"google","thirdPartyUserId":"g-4107","email":{"id":"dave@example.org","isVerified":true}}' >/dev/null
    call PUT recipe/role '{"role":"admin","permissions":["users:read","users:write"]}' >/dev/null
    call PUT recipe/role '{"role":"support","permissions":["users:read"]}' >/dev/null
    alice=$(id alice@example.com)
    call PUT recipe/user/role "$(jq -nc --arg u "$alice" '{userId: $u, role: "admin"}')" >/dev/null
    call POST recipe/session "$(jq -nc --arg u "$alice" '{userId: $u,
      userDataInJWT: {"st-role": {v: ["admin"], t: 0}, plan: "pro"},
      userDataInDatabase: {gh_token: "packtest-canary-supertokens-sessdb-9f3a"},
      enableAntiCsrf: false}')" >/dev/null
    call POST recipe/dashboard/user '{"email":"ops@example.com","password":"packtest-canary-supertokens-dash-6a1f"}' >/dev/null
    call POST recipe/signinup/code '{"email":"carol@example.com"}' >/dev/null
    call PUT recipe/multitenancy/config/thirdparty '{"tenantId":"public","config":{"thirdPartyId":"google","name":"Google","clients":[{"clientType":"web","clientId":"packtest-google-client","clientSecret":"packtest-canary-supertokens-google-secret-5d2e","scope":["email","openid"]}]},"skipValidation":true}' >/dev/null
    ;;
  *)
    printf '%s\n' "unknown fixture command: $command" >&2
    exit 2
    ;;
esac

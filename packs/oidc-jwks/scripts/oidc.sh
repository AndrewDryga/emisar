#!/bin/bash
set -euo pipefail

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

https_url() {
  [[ "$1" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~!$\&\'\(\)*+,=:;%@/-]*)?$ ]]
}

fetch_json() {
  local url=$1
  local max_bytes=$2
  local accepted_types=$3
  local body=$4
  local blocks metadata status content_type size
  local -a curl_args

  blocks=$(((max_bytes + 511) / 512))
  curl_args=(
    -q
    --silent
    --show-error
    --globoff
    --proto '=https'
    --proto-redir '=https'
    --max-redirs 0
    --connect-timeout 5
    --max-time 20
    --max-filesize "$max_bytes"
    --request GET
    --output "$body"
    --write-out $'%{http_code}\n%{content_type}'
  )
  if [[ -n "${OIDC_CA_CERT:-}" ]]; then
    curl_args+=(--cacert "$OIDC_CA_CERT")
  fi

  if ! metadata=$(
    (
      ulimit -f "$blocks"
      curl --fail "${curl_args[@]}" "$url"
    )
  ); then
    fail "OIDC HTTPS request failed"
  fi

  status=${metadata%%$'\n'*}
  content_type=${metadata#*$'\n'}
  content_type=${content_type%%;*}
  content_type=$(printf '%s' "$content_type" | tr '[:upper:]' '[:lower:]')
  [[ "$status" == 200 ]] || fail "OIDC endpoint returned a non-200 response"
  [[ ",$accepted_types," == *",$content_type,"* ]] ||
    fail "OIDC endpoint returned an unsupported content type"

  size=$(wc -c <"$body")
  ((size <= max_bytes)) || fail "OIDC response exceeded the size limit"
  jq -e 'type == "object"' "$body" >/dev/null ||
    fail "OIDC endpoint did not return a JSON object"
}

discovery_url() {
  local issuer=${1%/}
  printf '%s/.well-known/openid-configuration\n' "$issuer"
}

validate_discovery_document() {
  local body=$1
  jq -e '
    type == "object" and
    (.issuer | type == "string" and length > 0) and
    (.jwks_uri | type == "string" and length > 0)
  ' "$body" >/dev/null || fail "OIDC discovery is missing issuer or jwks_uri"
}

validate_jwks_document() {
  local body=$1
  jq -e '
    type == "object" and
    (.keys | type == "array" and length >= 1 and length <= 128) and
    all(.keys[];
      type == "object" and
      (.kty | type == "string" and length > 0) and
      (has("d") or has("p") or has("q") or has("dp") or has("dq") or
       has("qi") or has("oth") or has("k") | not)
    )
  ' "$body" >/dev/null || fail "JWKS is invalid or contains private key material"
}

mode=${1:-}

case "$mode" in
  discovery)
    issuer=$2
    https_url "$issuer" || fail "issuer must be a bounded HTTPS URL without credentials, query, or fragment"
    umask 077
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-oidc.XXXXXX")
    trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
    url=$(discovery_url "$issuer")
    fetch_json "$url" 262144 application/json "$tmp/body.json"
    validate_discovery_document "$tmp/body.json"
    cat "$tmp/body.json"
    ;;

  validate-discovery)
    issuer=$2
    https_url "$issuer" || fail "issuer must be a bounded HTTPS URL without credentials, query, or fragment"
    umask 077
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-oidc.XXXXXX")
    trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
    url=$(discovery_url "$issuer")
    fetch_json "$url" 262144 application/json "$tmp/body.json"
    validate_discovery_document "$tmp/body.json"
    jwks_uri=$(jq -er '.jwks_uri' "$tmp/body.json")
    https_url "$jwks_uri" || fail "discovery jwks_uri is not an accepted HTTPS URL"
    jq -ce --arg issuer "$issuer" --arg discovery_url "$url" --arg jwks_uri "$jwks_uri" '
      if .issuer != $issuer then error("discovery issuer does not exactly match the requested issuer")
      else {
        valid: true,
        issuer: .issuer,
        discovery_url: $discovery_url,
        jwks_uri: $jwks_uri
      }
      end
    ' "$tmp/body.json"
    ;;

  jwks)
    uri=$2
    https_url "$uri" || fail "jwks_uri must be a bounded HTTPS URL without credentials, query, or fragment"
    umask 077
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/emisar-oidc.XXXXXX")
    trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
    fetch_json "$uri" 1048576 application/json,application/jwk-set+json "$tmp/body.json"
    validate_jwks_document "$tmp/body.json"
    cat "$tmp/body.json"
    ;;

  compare-key-ids)
    : "${OIDC_AUTHORITATIVE_KEY_IDS_JSON:?missing authoritative key IDs}"
    : "${OIDC_CONSUMER_KEY_IDS_JSON:?missing consumer key IDs}"
    jq -nce '
      def ids($name):
        env[$name] | fromjson |
        if type != "array" or length > 128 or
           any(.[]; type != "string" or length == 0 or length > 256)
        then error($name + " must be a JSON array of at most 128 bounded strings")
        else unique | sort
        end;
      (ids("OIDC_AUTHORITATIVE_KEY_IDS_JSON")) as $authoritative |
      (ids("OIDC_CONSUMER_KEY_IDS_JSON")) as $consumer |
      ($authoritative - $consumer) as $missing |
      ($consumer - $authoritative) as $extra |
      {
        authoritative_key_ids: $authoritative,
        consumer_key_ids: $consumer,
        shared_key_ids: ($authoritative - $missing),
        missing_from_consumer: $missing,
        extra_in_consumer: $extra,
        exact_match: (($missing | length) == 0 and ($extra | length) == 0),
        consumer_covers_authoritative: (($missing | length) == 0),
        relation:
          (if ($missing | length) == 0 and ($extra | length) == 0 then "equal"
           elif ($missing | length) > 0 and ($extra | length) == 0 then "consumer_missing"
           elif ($missing | length) == 0 and ($extra | length) > 0 then "consumer_extra"
           else "consumer_missing_and_extra"
           end)
      }
    '
    ;;

  jwt-header)
    : "${OIDC_JWT:?missing JWT}"
    if [[ "$OIDC_JWT" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*$ ]]; then
      serialization=jws
      segment_count=3
    elif [[ "$OIDC_JWT" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
      serialization=jwe
      segment_count=5
    else
      fail "JWT must use compact JWS or JWE serialization"
    fi

    encoded_header=${OIDC_JWT%%.*}
    normalized=${encoded_header//-/+}
    normalized=${normalized//_/\/}
    case $((${#normalized} % 4)) in
      0) ;;
      2) normalized="${normalized}==" ;;
      3) normalized="${normalized}=" ;;
      *) fail "JWT protected header has invalid base64url length" ;;
    esac
    if ! header=$(printf '%s' "$normalized" | base64 --decode 2>/dev/null); then
      fail "JWT protected header is not valid base64url"
    fi
    ((${#header} <= 16384)) || fail "JWT protected header exceeded the size limit"

    HEADER_JSON=$header SERIALIZATION=$serialization SEGMENT_COUNT=$segment_count jq -nce '
      (env.HEADER_JSON | fromjson) as $header |
      if ($header | type) != "object" then
        error("JWT protected header must be a JSON object")
      elif ($header.alg | type) != "string" or ($header.alg | length) == 0 then
        error("JWT protected header must contain a non-empty alg")
      elif env.SERIALIZATION == "jwe" and
           (($header.enc | type) != "string" or ($header.enc | length) == 0) then
        error("JWE protected header must contain a non-empty enc")
      elif any(["alg", "enc", "kid", "typ", "cty", "zip", "jku", "x5u", "x5t", "x5t#S256"][];
               $header[.] != null and ($header[.] | type) != "string") then
        error("recognized JWT protected-header fields must be strings")
      elif $header.crit != null and
           (($header.crit | type) != "array" or ($header.crit | length) > 32 or
            any($header.crit[]; type != "string" or length == 0 or length > 256)) then
        error("JWT crit must be a bounded string array")
      else
        {
          serialization: env.SERIALIZATION,
          segment_count: (env.SEGMENT_COUNT | tonumber),
          alg: $header.alg,
          enc: ($header.enc // null),
          kid: ($header.kid // null),
          typ: ($header.typ // null),
          cty: ($header.cty // null),
          zip: ($header.zip // null),
          crit: ($header.crit // null),
          jku: ($header.jku // null),
          x5u: ($header.x5u // null),
          x5t: ($header.x5t // null),
          x5t_s256: ($header["x5t#S256"] // null),
          present_fields:
            (["alg", "enc", "kid", "typ", "cty", "zip", "crit", "jku", "x5u", "x5t", "x5t#S256"] |
             map(. as $name | select($header | has($name))))
        }
      end
    '
    ;;

  *)
    fail "unsupported OIDC operation"
    ;;
esac

#!/bin/bash
set -euo pipefail
export LC_ALL=C
umask 077

fail() { printf '%s\n' "$1" >&2; exit 1; }
readonly max_response_bytes=16777216
readonly max_summary_bytes=8192
readonly clipping_notice='Summary clipped at 8 KiB; more fields were omitted.'
domain=${1,,}
domain=${domain%.}
[[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != *..* &&
  "$domain" != .* && "$domain" != *. && ! "$domain" =~ ^[0-9.]+$ ]] || fail 'Invalid domain name'
IFS=. read -r -a labels <<<"$domain"
for label in "${labels[@]}"; do
  [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#label} -le 63 ]] || fail 'Invalid domain name'
done

bootstrap=https://data.iana.org/rdap/dns.json
protocols='=https'
if [[ "${NET_RDAP_PACKTEST:-}" == 1 ]]; then
  [[ "${NET_RDAP_BOOTSTRAP_URL:-}" == http://rdap-api:8080/bootstrap.json ]] || fail 'Invalid test bootstrap URL'
  bootstrap=http://rdap-api:8080/bootstrap.json
  protocols='=http,https'
elif [[ -n "${NET_RDAP_BOOTSTRAP_URL:-}" ]]; then
  fail 'Bootstrap override is test-only'
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/emisar-rdap.XXXXXXXX") || exit 1
trap 'rm -f -- "$scratch/whois" "$scratch/body" "$scratch/headers" "$scratch/summary" "$scratch/output"; rmdir -- "$scratch"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Capture before parsing. Head bounds chunked HTTP and a runaway WHOIS response,
# including when a client's own advertised-size check is absent or insufficient.
if timeout -k 1s 5s whois "$domain" 2>/dev/null |
  head -c "$((max_response_bytes + 1))" >"$scratch/whois"; then
  statuses=("${PIPESTATUS[@]}")
else
  statuses=("${PIPESTATUS[@]}")
fi
bytes=$(wc -c <"$scratch/whois")
if ((statuses[0] == 0 && statuses[1] == 0 && bytes > 0 && bytes <= max_response_bytes)); then
  # Match whole public labels; Registrar Abuse Contact and unrelated remarks do
  # not qualify. Never replay raw WHOIS output or a failed partial response.
  jq -Rrs '
    def space_trim:
      explode | . as $cs |
      ([range($cs|length) | select($cs[.] != 32 and $cs[.] != 9)]) as $ix |
      if ($ix|length) == 0 then "" else $cs[$ix[0]:($ix[-1]+1)] | implode end;
    def display: explode | map(if . >= 127 and . <= 159 then 32 else . end) | implode | @json;
    split("\n")[] | rtrimstr("\r") | split(":") |
    select(length >= 2) | (.[0] | space_trim | ascii_downcase) as $label |
    select(["domain name", "registrar", "registrar iana id", "creation date",
      "created", "updated date", "last modified", "registry expiry date",
      "registrar registration expiration date", "expiration date", "expiry date",
      "name server", "nserver", "domain status", "status"] | index($label)) |
    (.[1:] | join(":") | space_trim) as $value | select($value != "") |
    "\($label): \($value | display)"
  ' <"$scratch/whois" >"$scratch/summary" 2>/dev/null || fail 'WHOIS summary could not be parsed'
  if [[ -s "$scratch/summary" ]]; then
    source=WHOIS
  fi
fi

request() {
  local url=$1 http_code='' header_line
  if curl -q --globoff --proto "$protocols" --fail -sS \
    --connect-timeout 3 --max-time 10 --max-filesize "$max_response_bytes" \
    --dump-header "$scratch/headers" "$url" 2>/dev/null |
    head -c "$((max_response_bytes + 1))" >"$scratch/body"; then
    statuses=("${PIPESTATUS[@]}")
  else
    statuses=("${PIPESTATUS[@]}")
  fi
  bytes=$(wc -c <"$scratch/body")
  ((bytes <= max_response_bytes && statuses[0] != 63)) || fail 'RDAP response exceeded 16 MiB'
  while IFS= read -r header_line; do
    if [[ "$header_line" =~ ^HTTP/[0-9.]+[[:space:]]+([0-9]{3})([[:space:]]|$) ]]; then
      http_code=${BASH_REMATCH[1]}
    fi
  done <"$scratch/headers"
  [[ "$http_code" =~ ^2[0-9]{2}$ ]] && ((statuses[0] == 0 && statuses[1] == 0 && bytes > 0)) ||
    fail "RDAP request failed (HTTP ${http_code:-unknown}); domain availability is unknown"
}

valid_base() {
  local candidate=$1 authority port
  if [[ "${NET_RDAP_PACKTEST:-}" == 1 ]]; then
    [[ "$candidate" == http://rdap-api:8080/rdap/ ]]
    return
  fi
  # No userinfo, query, fragment, escapes, glob syntax or path traversal.
  [[ "$candidate" =~ ^https://([A-Za-z0-9-]+\.)+[A-Za-z0-9-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)*/$ &&
    "$candidate" != */../* && "$candidate" != */./* ]] || return 1
  authority=${candidate#https://}; authority=${authority%%/*}
  if [[ "$authority" == *:* ]]; then
    port=${authority##*:}
    ((10#$port >= 1 && 10#$port <= 65535)) || return 1
  fi
}

if [[ "${source:-}" != WHOIS ]]; then
  request "$bootstrap"
  bases=$(jq -ces --arg domain "$domain" '
    if length != 1 then error("invalid bootstrap") else .[0] end |
    if type != "object" or (.services|type) != "array" then error("invalid bootstrap") else . end |
    [.services[] |
      if type != "array" or length != 2 then error("invalid service") else . end |
      if (.[0]|type) != "array" or (.[1]|type) != "array" or (.[1]|length) == 0 then error("invalid service") else . end |
      .[1] as $urls | .[0][] |
      if type != "string" then error("invalid suffix") else ascii_downcase end |
      . as $suffix |
      select($suffix == "" or $domain == $suffix or ($domain | endswith("." + $suffix))) |
      {suffix: $suffix, urls: $urls}] |
    if length == 0 then error("no RDAP service") else sort_by(.suffix | length) | last.urls end |
    # Reject controls before shell decoding: command substitution drops trailing
    # newlines and Bash cannot preserve NUL, so validation afterward is too late.
    map(select(type == "string") | select(explode | all(.[]; . >= 33 and . <= 126))) |
    sort_by(startswith("https://") | not) | .[]
  ' <"$scratch/body" 2>/dev/null) || fail 'No usable RDAP service in IANA bootstrap'
  base=''
  # JSON lines keep embedded newlines inside one candidate; do not split an
  # invalid URL into separate fetchable strings. Pick one safe URL, never retry
  # another service or follow a referral after a failed domain lookup.
  while IFS= read -r encoded_base; do
    candidate=$(jq -er . <<<"$encoded_base")
    if valid_base "$candidate"; then base=$candidate; break; fi
  done <<<"$bases"
  [[ -n "$base" ]] || fail 'No safe RDAP base URL in IANA bootstrap'
  request "${base}domain/$domain"
  if ! jq -ers --arg domain "$domain" '
    def array_member($key):
      if has($key) then if .[$key]|type == "array" then .[$key] else error("invalid array") end else [] end;
    def object: if type == "object" then . else error("invalid object") end;
    def string: if type == "string" then . else error("invalid string") end;
    def display: string | explode | map(if . >= 127 and . <= 159 then 32 else . end) | implode | @json;
    if length != 1 then error("invalid document") else .[0] end | object |
    if has("errorCode") or .objectClassName != "domain" or (.ldhName|type) != "string" then error("invalid domain") else . end |
    if (.ldhName | ascii_downcase | rtrimstr(".")) != $domain then error("domain mismatch") else . end |
    # Build and validate the entire closed projection before writing any output.
    ["Domain: " + (.ldhName | display),
      (array_member("entities")[] | object |
        (array_member("roles") | map(string)) as $roles |
        select($roles | index("registrar")) |
        (if has("vcardArray") then
          .vcardArray |
          if type != "array" or length != 2 or .[0] != "vcard" or (.[1]|type) != "array" then error("invalid jCard") else .[1][] end |
          if type != "array" or length < 4 then error("invalid jCard property") else . end |
          select(.[0] == "fn") |
          if length != 4 or (.[1]|type) != "object" or .[2] != "text" then error("invalid registrar name") else "Registrar: " + (.[3]|display) end
        else empty end),
        (array_member("publicIds")[] | object | select(.type == "IANA Registrar ID") |
          "Registrar IANA ID: " + (.identifier | display))),
      (array_member("events")[] | object |
        "Event " + (.eventAction|display) + ": " + (.eventDate|display)),
      (array_member("nameservers")[] | object |
        if has("ldhName") then "Nameserver: " + (.ldhName|display) else empty end)
    ] | .[]
  ' <"$scratch/body" >"$scratch/summary" 2>/dev/null; then
    fail 'Invalid RDAP domain response; domain availability is unknown'
  fi
  source=RDAP
fi

# Keep whole escaped lines: no split UTF-8 and no runner truncation. Reserve the
# notice plus newline so the final result itself never exceeds the 8 KiB cap.
printf 'Source: %s\n' "$source" >"$scratch/output"
used=$(wc -c <"$scratch/output")
while IFS= read -r line; do
  if ((used + ${#line} + 1 + ${#clipping_notice} + 1 > max_summary_bytes)); then
    printf '%s\n' "$clipping_notice" >>"$scratch/output"
    break
  fi
  printf '%s\n' "$line" >>"$scratch/output"
  used=$((used + ${#line} + 1))
done <"$scratch/summary"
cat "$scratch/output"

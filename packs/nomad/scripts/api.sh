#!/bin/sh
# Fixed API requests: preserve Nomad client configuration without following redirects.
set -eu
method=$1
path=$2
json_type=$3
namespace=$4
region=$5
case "$method:$json_type" in
GET:object|GET:array|GET:string|PUT:object) ;;
*) printf '%s\n' 'Invalid Nomad API request' >&2; exit 1 ;;
esac
[ -z "$namespace" ] || export NOMAD_NAMESPACE="$namespace"
[ -z "$region" ] || export NOMAD_REGION="$region"

# Native initialization validates CA files/directories and client key pairs,
# even with skip_verify. Its dry-run output contains credentials: discard it.
# The dry-run renderer (not TLS initialization) requires a port for SNI.
if ! NOMAD_TLS_SERVER_NAME='' nomad operator api -dryrun -X "$method" "$path" </dev/null >/dev/null 2>&1; then
	printf '%s\n' 'Invalid Nomad client configuration' >&2
	exit 1
fi

umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/emisar-nomad-api.XXXXXXXX")
trap 'rm -rf -- "$work"' 0
trap 'exit 143' TERM HUP
trap 'exit 130' INT
mkdir "$work/empty-ca"
export EMISAR_NOMAD_API_CA='' EMISAR_NOMAD_API_EMPTY_CA="$work/empty-ca" EMISAR_NOMAD_API_CERT=''

if [ -n "${NOMAD_CLIENT_CERT:-}" ]; then
	# curl's cert option interprets literal ':' as a password separator even
	# after config quoting. Nomad reads the filename literally; use a safe copy.
	if ! cat -- "$NOMAD_CLIENT_CERT" >"$work/client.pem" 2>/dev/null; then
		printf '%s\n' 'Invalid Nomad client certificate' >&2
		exit 1
	fi
	export EMISAR_NOMAD_API_CERT="$work/client.pem"
fi

if [ -n "${NOMAD_CACERT:-}" ] || [ -n "${NOMAD_CAPATH:-}" ]; then
	if [ -n "${NOMAD_CACERT:-}" ]; then
		cat -- "$NOMAD_CACERT" >"$work/roots"
	else
		# Nomad reads ordinary PEM files recursively, not OpenSSL's hashed capath.
		(cd "$NOMAD_CAPATH" && find . ! -type d -exec awk 'FNR == 1 { print "" } { print }' {} +) >"$work/roots"
	fi
	# Go's root loader accepts headerless CERTIFICATE blocks only. In particular,
	# do not broaden trust through OpenSSL TRUSTED CERTIFICATE blocks in a bundle.
	awk '
		{ sub(/\r$/, ""); sub(/[ \t]+$/, "") }
		/^-----BEGIN CERTIFICATE-----$/ { block=$0 "\n"; reading=1; headers=0; next }
		reading && /^-----END CERTIFICATE-----$/ {
			if (!headers) printf "%s%s\n", block, $0
			reading=0; next
		}
		reading { if (index($0, ":")) headers=1; block=block $0 "\n" }
	' "$work/roots" >"$work/ca.pem"
	export EMISAR_NOMAD_API_CA="$work/ca.pem"
fi

# Credentials stay in a mode-0600 config file, never curl's argv. Encode curl's
# actual quoted-string syntax, not JSON's unsupported \b/\f/\u escapes.
if ! jq -nr --arg path "$path" '
  def quote:
    "\"" + (explode | map(
      if . == 34 then "\\\"" elif . == 92 then "\\\\"
      elif . == 9 then "\\t" elif . == 10 then "\\n"
      elif . == 13 then "\\r" elif . == 11 then "\\v"
      else [.] | implode end) | join("")) + "\"";
  def option($name; $value): $name + " = " + ($value | quote);
  def header_value: explode | all(. == 9 or (. >= 32 and . != 127));
  (env.NOMAD_ADDR // "" | if . == "" then "http://127.0.0.1:4646" else . end) as $addr
  | ($addr | split("://")) as $parts
  | $parts[0] as $transport
  | if ($parts | length) != 2 or (["http", "https", "unix"] | index($transport)) == null
    then error("address") else . end
  | (["1", "t", "T", "true", "TRUE", "True"] | index(env.NOMAD_SKIP_VERIFY // "")) as $skip_verify
  | (if (env.NOMAD_CACERT // "") != "" or (env.NOMAD_CAPATH // "") != "" or
         (env.NOMAD_CLIENT_CERT // "") != "" or (env.NOMAD_TLS_SERVER_NAME // "") != "" or $skip_verify != null
     then "https" elif $transport == "unix" then "http" else $transport end) as $scheme
  | (if $transport == "unix" then "127.0.0.1"
     else $parts[1] | split("/")[0] | split("?")[0] | split("#")[0] | split("@")[-1] end) as $host_port
  | (if $host_port | startswith("[") then ($host_port | split("]")[0]) + "]"
     else $host_port | split(":")[0] end) as $host
  | (if $host_port | startswith("[") then $host_port | split("]")[1] | ltrimstr(":")
     elif $host_port | contains(":") then $host_port | split(":")[-1] else "" end) as $explicit_port
  | (if $explicit_port != "" then $explicit_port elif $scheme == "https" then "443" else "80" end) as $port
  | (env.NOMAD_TLS_SERVER_NAME // "") as $sni
  | (if $sni | contains(":") then "[" + $sni + "]" else $sni end) as $tls_host
  | (if $scheme == "https" and $sni != "" then "https://" + $tls_host + ":" + $port
     else $scheme + "://" + $host_port end) as $base
  | ([
      if (env.NOMAD_NAMESPACE // "") != "" then "namespace=" + (env.NOMAD_NAMESPACE | @uri) else empty end,
      if (env.NOMAD_REGION // "") != "" then "region=" + (env.NOMAD_REGION | @uri) else empty end
    ] | join("&")) as $query
  | option("url"; $base + $path + (if $query == "" then "" elif $path | contains("?") then "&" + $query else "?" + $query end)),
    (if $transport == "unix" then option("unix-socket"; $parts[1] | split("?")[0] | split("#")[0]) else empty end),
    (if $scheme == "https" and $sni != "" then
      (if $transport != "unix" then option("connect-to"; $tls_host + ":" + $port + ":" + $host + ":" + $port) else empty end),
      option("header"; "Host: " + $host_port)
    else empty end),
    (if (env.NOMAD_TOKEN // "") != "" then
      if env.NOMAD_TOKEN | header_value then option("header"; "X-Nomad-Token: " + env.NOMAD_TOKEN)
      else error("token header") end
    else empty end),
    (if (env.NOMAD_HTTP_AUTH // "") != "" then
      option("header"; "Authorization: Basic " +
        (env.NOMAD_HTTP_AUTH | if contains(":") then . else . + ":" end | @base64))
    else empty end),
    (if env.EMISAR_NOMAD_API_CA != "" then
      option("cacert"; env.EMISAR_NOMAD_API_CA), option("capath"; env.EMISAR_NOMAD_API_EMPTY_CA)
    else empty end),
    (if env.EMISAR_NOMAD_API_CERT != "" then option("cert"; env.EMISAR_NOMAD_API_CERT), option("key"; env.NOMAD_CLIENT_KEY) else empty end),
    (if $skip_verify != null then "insecure" else empty end)
' >"$work/config" 2>/dev/null; then
	printf '%s\n' 'Invalid Nomad API configuration' >&2
	exit 1
fi

status=0
code=$(ulimit -f 2048 || exit 1; curl -q --config "$work/config" --globoff --proto '=http,https' \
	--http1.1 --tlsv1.2 --compressed --fail-with-body --silent \
	--request "$method" --output "$work/body" --write-out '%{http_code}' 2>/dev/null) || status=$?
case "$code:$status" in
2[0-9][0-9]:0)
	if jq -es --arg expected "$json_type" 'length == 1 and (.[0] | type) == $expected' "$work/body" >/dev/null 2>&1; then
		cat "$work/body"
		exit 0
	fi
	printf '%s\n' 'Nomad API returned an invalid JSON response' >&2
	;;
*) printf 'Nomad API request failed (HTTP %s, transport %s)\n' "$code" "$status" >&2 ;;
esac
[ ! -f "$work/body" ] || cat "$work/body" >&2
exit 1

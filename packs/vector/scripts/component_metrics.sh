#!/bin/sh
set -eu
umask 077
export LC_ALL=C

fail() { printf '%s\n' "$1" >&2; exit 1; }

# Older curl cannot enforce max-filesize on a chunked/unknown-length response.
if ! curl -q --fail --globoff --proto '=http,https' --version | awk 'NR == 1 {
  split($2, v, "."); exit !(v[1] > 8 || (v[1] == 8 && v[2] >= 4))
}'; then
  fail 'Vector metrics require curl 8.4 or later for bounded downloads.'
fi

tmp=$(mktemp -d /tmp/emisar-vector-metrics.XXXXXX)
trap 'rm -f -- "$tmp/config" "$tmp/body" "$tmp/status" "$tmp/diagnostic" "$tmp/counters"; rmdir -- "$tmp"' EXIT
trap 'exit 130' HUP INT TERM

# The configured URL and unprojected response never enter argv or diagnostics.
url=${VECTOR_METRICS_URL:-http://127.0.0.1:9598/metrics}
case "$url" in
  http://*|https://*) ;;
  *) fail 'VECTOR_METRICS_URL must use HTTP or HTTPS.' ;;
esac
if ! printf '%s' "$url" | od -An -tu1 | awk '{ for (i=1; i<=NF; i++) if ($i<32 || $i==127) exit 1 }'; then
  fail 'VECTOR_METRICS_URL contains invalid control characters.'
fi
if ! printf '%s' "$url" | awk '
  BEGIN { printf "url = \"" }
  {
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c == "\\" || c == "\"") printf "\\%s", c
      else printf "%s", c
    }
  }
  END { printf "\"\n" }
' >"$tmp/config"; then
  fail 'VECTOR_METRICS_URL contains invalid control characters.'
fi
rc=0
curl -q --config "$tmp/config" --fail --silent --show-error --globoff \
  --proto '=http,https' --connect-timeout 3 --max-time 12 --max-filesize 1048576 \
  --output "$tmp/body" --write-out '%{http_code}' \
  >"$tmp/status" 2>"$tmp/diagnostic" || rc=$?
status=$(cat "$tmp/status")
if [ "$rc" -ne 0 ]; then
  printf 'Vector metrics request failed (client code %s, HTTP %s). Check the exporter and VECTOR_METRICS_URL.\n' "$rc" "$status" >&2
  exit "$rc"
fi
case "$status" in
  200) ;;
  *) fail 'Vector metrics endpoint did not return HTTP 200; redirects are not followed.' ;;
esac
[ "$(wc -c <"$tmp/body")" -le 1048576 ] || fail 'Vector metrics response exceeds the 1 MiB budget.'

# Parse the exporter legacy text format, not a grep of arbitrary label values.
# Retain only component identity; sum distinct series over all other dimensions.
# A malformed target after a valid one still fails without emitting that prefix.
if ! awk '
function bad(message) {
  failed = 1
  print message > "/dev/stderr"
  exit 1
}
function ws() { while (substr(s, p, 1) ~ /^[ \t]$/) p++ }
function quoted( start, c) {
  start = p
  if (substr(s, p++, 1) != "\"") bad("Invalid Vector counter label.")
  while (p <= length(s)) {
    c = substr(s, p++, 1)
    if (c == "\"") return substr(s, start, p-start)
    if (c == "\\") {
      c = substr(s, p++, 1)
      if (c != "\\" && c != "\"" && c != "n") bad("Invalid Vector counter escape.")
    } else if (c ~ /[[:cntrl:]]/) bad("Invalid Vector counter control character.")
  }
  bad("Unterminated Vector counter label.")
}
function finite(n, text) {
  text = sprintf("%.17g", n)
  return n >= 0 && text ~ /^[+]?[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?$/
}
function timestamp(t, negative) {
  negative = (substr(t, 1, 1) == "-")
  sub(/^[+-]/, "", t); sub(/^0+/, "", t)
  return length(t) < 19 || (length(t) == 19 &&
    ("x" t <= (negative ? "x9223372036854775808" : "x9223372036854775807")))
}
{
  s = $0; sub(/^[ \t]+/, "", s); p = 1
  if (!match(s, /^[a-zA-Z_:][a-zA-Z0-9_:]*/)) next
  metric = substr(s, 1, RLENGTH); p += RLENGTH
  if (metric !~ /^vector_component_[a-zA-Z0-9_]+_total$/) next
  for (name in labels) delete labels[name]
  ws()
  if (substr(s, p++, 1) != "{") bad("Vector counters need component identity labels.")
  ws()
  while (substr(s, p, 1) != "}") {
    rest = substr(s, p)
    if (!match(rest, /^[a-zA-Z_][a-zA-Z0-9_]*/)) bad("Invalid Vector counter label name.")
    name = substr(rest, 1, RLENGTH); p += RLENGTH; ws()
    if (name in labels) bad("Duplicate Vector counter label.")
    if (substr(s, p++, 1) != "=") bad("Invalid Vector counter label assignment.")
    ws(); labels[name] = quoted(); ws()
    c = substr(s, p++, 1)
    if (c == "}") { p--; break }
    if (c != ",") bad("Invalid Vector counter label separator.")
    ws()
  }
  p++
  if (substr(s, p, 1) !~ /^[ \t]$/) bad("Vector counter is missing its value.")
  ws(); rest = substr(s, p); sub(/[ \t]+$/, "", rest)
  count = split(rest, tokens, /[ \t]+/)
  if (count < 1 || count > 2 || tokens[1] !~ /^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/ ||
      (count == 2 && (tokens[2] !~ /^[+-]?[0-9]+$/ || !timestamp(tokens[2]))))
    bad("Invalid Vector counter value or timestamp.")
  value = tokens[1] + 0
  if (!finite(value)) bad("Vector counter must be finite and nonnegative.")
  for (i = 1; i <= 3; i++) {
    name = (i == 1 ? "component_id" : (i == 2 ? "component_kind" : "component_type"))
    if (!(name in labels) || labels[name] == "\"\"") bad("Vector counter is missing component identity.")
  }
  projected = metric "{component_id=" labels["component_id"] ",component_kind=" labels["component_kind"] ",component_type=" labels["component_type"] "}"
  # Canonicalize the entire label set, independent of provider label order.
  series = metric; previous = ""; remaining = 0
  for (name in labels) remaining++
  while (remaining-- > 0) {
    first = 1
    for (name in labels) {
      if (name > previous && (first || name < chosen)) { chosen = name; first = 0 }
    }
    series = series length(chosen) ":" chosen length(labels[chosen]) ":" labels[chosen]
    previous = chosen
  }
  if (series in seen) bad("Duplicate Vector counter series.")
  seen[series] = 1
  totals[projected] += value
  if (!finite(totals[projected])) bad("Vector counter aggregate overflow.")
  samples++
}
END {
  if (failed) exit 1
  if (!samples) {
    print "No Vector component counters found. Configure internal_metrics with the vector namespace and a prometheus_exporter sink." > "/dev/stderr"
    exit 1
  }
  for (projected in totals) printf "%s %.17g\n", projected, totals[projected]
}
' "$tmp/body" >"$tmp/counters" 2>"$tmp/diagnostic"; then
  cat "$tmp/diagnostic" >&2
  exit 1
fi
[ "$(wc -c <"$tmp/counters")" -le 1048576 ] || fail 'Vector component counters exceed the 1 MiB output budget.'
sort "$tmp/counters"

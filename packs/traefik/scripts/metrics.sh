#!/bin/sh
# Fetch privately before projecting: a failed scrape must not look successful,
# and a busy ingress must not stream megabytes through the runner's redactor.
set -eu
umask 077

prefix=$1
max_samples=$2
include_buckets=$3
base_url=${TRAEFIK_METRICS_URL:-${TRAEFIK_URL:-http://127.0.0.1:8080}}
K=""
if [ "${TRAEFIK_INSECURE:-}" = true ]; then K="-k"; fi

work=$(mktemp -d "${TMPDIR:-/tmp}/emisar-traefik-metrics.XXXXXXXX")
trap 'rm -f -- "$work/body" "$work/status" "$work/output"; rmdir -- "$work"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

get() {
	# Match the pack's other HTTP helpers: basic auth goes through stdin,
	# never process arguments. Per-request time/body bounds belong below.
	if [ -n "${TRAEFIK_BASICAUTH:-}" ]; then
		printf 'Authorization: Basic %s\n' "$(printf '%s' "$TRAEFIK_BASICAUTH" | base64 | tr -d '\n')" |
			curl -q --globoff --proto '=http,https' -fsS $K -H @- "$@" "$base_url/metrics"
	else
		curl -q --globoff --proto '=http,https' -fsS $K "$@" "$base_url/metrics"
	fi
}

# Read one byte beyond the input budget even without Content-Length. Preserve
# curl's status independently of head, including partial HTTP/transport errors.
{
	rc=0
	get --connect-timeout 5 --max-time 20 || rc=$?
	printf '%s\n' "$rc" >"$work/status"
} | head -c 8388609 >"$work/body"
bytes=$(wc -c <"$work/body")
[ "$bytes" -le 8388608 ] || { printf '%s\n' 'Traefik metrics exceeded 8 MiB; no samples returned' >&2; exit 1; }
rc=$(cat "$work/status")
case "$rc" in ''|*[!0-9]*) exit 1 ;; esac
[ "$rc" -eq 0 ] || exit "$rc"

# LC_ALL=C makes length() count bytes, including non-ASCII label values.
# Never cut a sample or rewrite its labels. Continue counting after a limit,
# so the final Prometheus comment states exactly what this selection omitted.
LC_ALL=C awk -v prefix="$prefix" -v maximum="$max_samples" -v buckets="$include_buckets" '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  {
    if (!match($0, /^[a-zA-Z_:][a-zA-Z0-9_:]*/) ||
        $0 !~ /^[a-zA-Z_:][a-zA-Z0-9_:]*(\{.*\})?[ \t]+([-+]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?|NaN|[-+]?Inf)([ \t]+[-+]?[0-9]+)?[ \t]*$/) {
      invalid = 1
      next
    }
    name = substr($0, RSTART, RLENGTH)
    if (index(name, prefix) != 1 && prefix != "") next
    if (buckets != "true" && name ~ /_bucket$/) { skipped_buckets++; next }
    matching++
    size = length($0) + 1
    if (returned >= maximum || emitted_bytes + size > 65536) { omitted++; next }
    print
    returned++
    emitted_bytes += size
  }
  END {
    if (invalid) {
      print "Traefik metrics returned invalid Prometheus samples; no samples returned" > "/dev/stderr"
      exit 1
    }
    printf "# emisar_metrics returned=%d matching=%d omitted=%d skipped_buckets=%d sample_bytes=%d truncated=%s\n", returned, matching, omitted, skipped_buckets, emitted_bytes, omitted ? "true" : "false"
  }
' "$work/body" >"$work/output"
cat "$work/output"

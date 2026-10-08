#!/bin/sh
# Only the destination address changes. URL identity owns HTTP Host and TLS.
set -eu
mode=$1
url=$2
resolve=$3
insecure=$4
max_time=$5

reject_mapping() {
	printf '%s\n' 'Resolve mapping must match the URL hostname and port and contain one literal IP address.' >&2
	exit 2
}

set --
[ "$insecure" != true ] || set -- -k
if [ -n "$resolve" ]; then
	authority=${url#*://}
	authority=${authority%%/*}
	authority=${authority%%\?*}
	case "$authority" in ""|*@*|*%*|*\[*|*\]*|*:*:*) reject_mapping ;; esac
	case "$url" in https://*) port=443 ;; http://*) port=80 ;; *) reject_mapping ;; esac
	case "$authority" in
	*:*) host=${authority%:*}; port=${authority##*:} ;;
	*) host=$authority ;;
	esac
	case "$port" in ""|*[!0-9]*) reject_mapping ;; esac
	# Strip leading zeros without shell arithmetic's octal interpretation.
	while [ "${port#0}" != "$port" ]; do port=${port#0}; done
	[ -n "$port" ] && [ "$port" -le 65535 ] || reject_mapping
	mapped_host=${resolve%%:*}
	rest=${resolve#*:}
	mapped_port=${rest%%:*}
	address=${rest#*:}
	[ "$mapped_port" -le 65535 ] || reject_mapping
	url_host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
	mapped_host=$(printf '%s' "$mapped_host" | tr '[:upper:]' '[:lower:]')
	[ "$url_host" = "$mapped_host" ] && [ "$port" = "$mapped_port" ] || reject_mapping
	# curl's own IP parser rejects malformed literals before any transfer.
	# Bypass proxies only for this explicit destination override.
	set -- "$@" --resolve "$url_host:$port:$address" --noproxy '*'
fi

case "$mode" in
probe)
	exec curl -q -sS --globoff --proto =http,https "$@" -o /dev/null --max-time "$max_time" \
		-w 'http_code=%{http_code}\nlookup=%{time_namelookup}\nconnect=%{time_connect}\nappconnect=%{time_appconnect}\nstarttransfer=%{time_starttransfer}\ntotal=%{time_total}\nsize=%{size_download}\n' "$url"
	;;
headers)
	exec curl -q -sSIL --globoff --proto =http,https --proto-redir =http,https \
		--max-redirs 5 "$@" --max-time "$max_time" "$url"
	;;
*) exit 2 ;;
esac

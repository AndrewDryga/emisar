#!/bin/sh
set -eu
umask 077
root=/tmp/packtest-net-fixture
case "$1" in
start)
	mkdir "$root"
	name=packtest.invalid
	[ "${2:-valid}" != wrong-san ] || name=wrong.invalid
	openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=Packtest-CA -keyout "$root/ca.key" -out "$root/ca.crt" -days 1 >"$root/openssl.log" 2>&1
	openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$name" -keyout "$root/server.key" -out "$root/server.csr" >>"$root/openssl.log" 2>&1
	printf 'subjectAltName=DNS:%s\n' "$name" >"$root/extensions"
	openssl x509 -req -in "$root/server.csr" -CA "$root/ca.crt" -CAkey "$root/ca.key" -CAcreateserial -out "$root/server.crt" -days 1 -extfile "$root/extensions" >>"$root/openssl.log" 2>&1
	python3 /packs/network-tls/test/fixtures/http-server.py >"$root/server.log" 2>&1 &
	pid=$!
	printf '%s\n' "$pid" >"$root/pid"
	for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		[ ! -f "$root/ready" ] || exit 0
		kill -0 "$pid" || { cat "$root/server.log" >&2; exit 1; }
		sleep 0.1
	done
	echo 'HTTP/TLS fixture did not become ready' >&2
	exit 1
	;;
stop)
	[ ! -f "$root/pid" ] || kill "$(cat "$root/pid")" 2>/dev/null || true
	;;
observe)
	jq -es 'any(.[]; .host == "packtest.invalid:24443" and .sni == "packtest.invalid" and .method == "GET")' "$root/requests.jsonl" >/dev/null
	printf '%s\n' 'HTTP Host and TLS SNI retained'
	;;
matrix)
	mode=$2
	scratch=$(mktemp -d /tmp/net-http-matrix.XXXXXX)
	mapping=
	finish() {
		status=$?
		if [ "$status" -ne 0 ]; then
			printf 'HTTP fixture check failed: %s / %s\n' "$mode" "$mapping" >&2
			[ ! -f "$scratch/result" ] || jq '{status,reason,stdout,stderr}' "$scratch/result" >&2
		fi
		rm -rf "$scratch"
		exit "$status"
	}
	trap finish EXIT
	trap 'exit 143' HUP INT TERM
	cp /workspace/test-packs/test-config.yaml "$scratch/config.yaml"
	chmod 600 "$scratch/config.yaml"
	export CURL_CA_BUNDLE="$root/ca.crt"
	run_action() {
		result_status=0
		emisar --config "$scratch/config.yaml" action run "$@" --reason 'Verify HTTP destination mapping' >"$scratch/result" 2>"$scratch/err" || result_status=$?
	}
	success() {
		[ "$result_status" -eq 0 ] || { cat "$scratch/result" "$scratch/err" >&2; exit 1; }
		jq -e '.status == "success" and .exit_code == 0' "$scratch/result" >/dev/null
	}
	failure() {
		[ "$result_status" -ne 0 ]
		jq -e '.status == "failed"' "$scratch/result" >/dev/null
	}
	case "$mode" in
	expiry-sni)
		for host in 127.0.0.1 ::1 localhost; do
			run_action net.tls_cert_expiry --arg "host=$host" --arg port=24443
			success
			jq -e '.stdout | contains("notAfter=") and contains("packtest.invalid")' "$scratch/result" >/dev/null
		done
		jq -es '[.[] | select(.port == 24443)] | length == 3 and .[0].name == null and .[1].name == null and .[2].name == "localhost"' "$root/sni.jsonl" >/dev/null
		;;
	addresses)
		for endpoint in 'https://packtest.invalid:24443/selected|packtest.invalid:24443:127.0.0.1' 'https://packtest.invalid:24446/selected|packtest.invalid:24446:[::1]' 'https://packtest.invalid|packtest.invalid:443:127.0.0.1' 'http://packtest.invalid|packtest.invalid:80:127.0.0.1' 'http://PACKTEST.invalid:24480/path:443?q=a:80|packtest.invalid:24480:127.0.0.1' 'http://packtest.invalid:00080/selected|packtest.invalid:80:127.0.0.1'; do
			run_action net.http_probe --arg "url=${endpoint%%|*}" --arg "resolve=${endpoint#*|}"
			success
			jq -e '.stdout | contains("http_code=201")' "$scratch/result" >/dev/null
			run_action net.http_headers --arg "url=${endpoint%%|*}" --arg "resolve=${endpoint#*|}"
			success
			jq -e '.stdout | contains("HTTP/1.0 201")' "$scratch/result" >/dev/null
		done
		jq -es 'any(.[]; .host == "packtest.invalid:24446" and .sni == "packtest.invalid") and any(.[]; .host == "packtest.invalid" and .sni == "packtest.invalid" and .port == 443)' "$root/requests.jsonl" >/dev/null
		;;
	proxy-status)
		export http_proxy=http://127.0.0.1:24481 no_proxy=
		run_action net.http_probe --arg url=http://packtest.invalid:24480/selected
		success
		jq -e '.stdout | contains("http_code=203")' "$scratch/result" >/dev/null
		run_action net.http_probe --arg url=http://packtest.invalid:24480/selected --arg resolve=packtest.invalid:24480:127.0.0.1
		success
		jq -e '.stdout | contains("http_code=201")' "$scratch/result" >/dev/null
		unset http_proxy no_proxy
		for code in 404 503; do
			run_action net.http_probe --arg "url=http://packtest.invalid:24480/status/$code" --arg resolve=packtest.invalid:24480:127.0.0.1
			success
			jq -e --arg code "$code" '.stdout | contains("http_code=" + $code)' "$scratch/result" >/dev/null
		done
		jq -es 'any(.[]; .port == 24481 and .path == "http://packtest.invalid:24480/selected") and any(.[]; .port == 24480 and .path == "/selected")' "$root/requests.jsonl" >/dev/null
		;;
	redirects)
		run_action net.http_probe --arg url=http://packtest.invalid:24480/redirect-same --arg resolve=packtest.invalid:24480:127.0.0.1
		success
		jq -e '.stdout | contains("http_code=302")' "$scratch/result" >/dev/null
		[ "$(wc -l <"$root/requests.jsonl")" -eq 2 ]
		run_action net.http_headers --arg url=http://packtest.invalid:24480/redirect-same --arg resolve=packtest.invalid:24480:127.0.0.1
		success
		jq -e '.stdout | contains("HTTP/1.0 302") and contains("HTTP/1.0 201")' "$scratch/result" >/dev/null
		for destination in host port; do
			run_action net.http_headers --arg "url=http://packtest.invalid:24480/redirect-$destination" --arg resolve=packtest.invalid:24480:127.0.0.1
			failure
			jq -e '.stderr | contains("Could not resolve host")' "$scratch/result" >/dev/null
		done
		run_action net.http_headers --arg url=http://packtest.invalid:24480/redirect-tcp --arg resolve=packtest.invalid:24480:127.0.0.1
		success
		jq -e '.stdout | contains("nginx")' "$scratch/result" >/dev/null
		run_action net.http_headers --arg url=http://packtest.invalid:24480/loop?n=0 --arg resolve=packtest.invalid:24480:127.0.0.1
		failure
		jq -e '.stderr | contains("Maximum (5) redirects followed")' "$scratch/result" >/dev/null
		run_action net.http_headers --arg url=http://packtest.invalid:24480/redirect-file --arg resolve=packtest.invalid:24480:127.0.0.1
		failure
		jq -e '.stderr | contains("disabled")' "$scratch/result" >/dev/null
		;;
	inputs)
		before=$(wc -l <"$root/requests.jsonl")
		for action in net.http_probe net.http_headers; do
			for mapping in '*:24480:127.0.0.1' '+packtest.invalid:24480:127.0.0.1' 'packtest.invalid:24480:127.0.0.1,127.0.0.2' 'packtest.invalid:0:127.0.0.1' 'packtest.invalid:65536:127.0.0.1' 'other.invalid:24480:127.0.0.1' 'packtest.invalid:443:127.0.0.1' 'packtest.invalid:24480:999.1.1.1' 'packtest.invalid:24480:[:::1]' 'packtest.invalid:24480:127.0.0.1;echo' 'packtest.invalid:24480:127.0.0.1
bad'; do
				run_action "$action" --arg url=http://packtest.invalid:24480/selected --arg "resolve=$mapping"
				[ "$result_status" -ne 0 ]
				jq -e '.status == "validation_failed" or .status == "failed"' "$scratch/result" >/dev/null
			done
			for url in 'http://user@packtest.invalid:24480/selected' 'http://packtest%2Einvalid:24480/selected' 'http://packtest.invalid:0/selected' 'http://packtest.invalid:65536/selected'; do
				run_action "$action" --arg "url=$url" --arg resolve=packtest.invalid:24480:127.0.0.1
				[ "$result_status" -ne 0 ]
			done
		done
		[ "$(wc -l <"$root/requests.jsonl")" -eq "$before" ]
		;;
	*) exit 2 ;;
	esac
	printf '%s\n' "HTTP $mode contract verified"
	;;
*) exit 2 ;;
esac

#!/bin/sh
# A TLS 1.2 listener on 127.0.0.1:24443 that presents a two-certificate chain,
# for nginx.ssl_chain_check. TLS 1.2 is what makes s_client print the session
# id, ticket and master key the action must not return.
set -eu
umask 077
root=/tmp/packtest-tls-chain
case "$1" in
start)
	mkdir "$root"
	openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=Packtest-Chain-CA -keyout "$root/ca.key" -out "$root/ca.crt" -days 1 >"$root/openssl.log" 2>&1
	openssl req -new -newkey rsa:2048 -nodes -subj /CN=packtest-chain.example -keyout "$root/server.key" -out "$root/server.csr" >>"$root/openssl.log" 2>&1
	openssl x509 -req -in "$root/server.csr" -CA "$root/ca.crt" -CAkey "$root/ca.key" -CAcreateserial -out "$root/server.crt" -days 1 >>"$root/openssl.log" 2>&1
	openssl s_server -quiet -accept 24443 -cert "$root/server.crt" -key "$root/server.key" -cert_chain "$root/ca.crt" -tls1_2 >"$root/server.log" 2>&1 &
	printf '%s\n' "$!" >"$root/pid"
	;;
verify-raw)
	# The raw handshake really carries the session text the action drops.
	openssl s_client -connect 127.0.0.1:24443 -servername packtest-chain.example -showcerts </dev/null >"$root/raw" 2>"$root/raw.err"
	for field in SSL-Session Session-ID Master-Key 'TLS session ticket'; do
		grep -Fq "$field" "$root/raw"
	done
	printf '%s\n' 'raw TLS 1.2 session verified'
	;;
stop)
	[ ! -f "$root/pid" ] || kill "$(cat "$root/pid")" 2>/dev/null || true
	;;
*) exit 2 ;;
esac

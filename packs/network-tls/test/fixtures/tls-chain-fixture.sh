#!/bin/sh
set -eu
umask 077
root=/tmp/packtest-tls-chain
case "$1" in
start)
	mkdir "$root"
	protocol=${2:-tls1_2}
	case "$protocol" in tls1_2|tls1_3) : ;; *) exit 2 ;; esac
	openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=Packtest-Chain-CA -keyout "$root/ca.key" -out "$root/ca.crt" -days 1 >"$root/openssl.log" 2>&1
	openssl req -new -newkey rsa:2048 -nodes -subj /CN=packtest-chain.example -keyout "$root/server.key" -out "$root/server.csr" >>"$root/openssl.log" 2>&1
	openssl x509 -req -in "$root/server.csr" -CA "$root/ca.crt" -CAkey "$root/ca.key" -CAcreateserial -out "$root/server.crt" -days 1 >>"$root/openssl.log" 2>&1
	# Force TLS1.2: s_client must produce the session fields the action drops.
	openssl s_server -quiet -accept 24443 -cert "$root/server.crt" -key "$root/server.key" -cert_chain "$root/ca.crt" "-$protocol" >"$root/server.log" 2>&1 &
	printf '%s\n' "$!" >"$root/pid"
	;;
verify-raw-tls12)
	openssl s_client -connect 127.0.0.1:24443 -servername 127.0.0.1 -showcerts </dev/null >"$root/raw" 2>"$root/raw.err"
	for field in SSL-Session Session-ID Master-Key 'TLS session ticket'; do
		grep -Fq "$field" "$root/raw"
	done
	[ "$(grep -c '^-----BEGIN CERTIFICATE-----$' "$root/raw")" -eq 2 ]
	printf '%s\n' 'Real TLS1.2 session and two certificates verified'
	;;
stop)
	[ ! -f "$root/pid" ] || kill "$(cat "$root/pid")" 2>/dev/null || true
	;;
*) exit 2 ;;
esac

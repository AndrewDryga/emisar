#!/bin/sh
set -eu

# Exercise the packaged SSL/crypto NIFs without depending on external services.
# The CA, leaf certificate and listener exist only for this image smoke test.
umask 077
tls_dir=$(mktemp -d)
server_pid=
cleanup() {
  rc=$?
  trap - EXIT
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f "$tls_dir/ca-key.pem" "$tls_dir/ca.pem" "$tls_dir/key.pem" \
    "$tls_dir/request.pem" "$tls_dir/cert.pem" "$tls_dir/server.log"
  rmdir "$tls_dir"
  exit "$rc"
}
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -noenc -sha256 -days 1 \
  -keyout "$tls_dir/ca-key.pem" -out "$tls_dir/ca.pem" \
  -subj '/CN=Emisar isolated image smoke CA' \
  -addext basicConstraints=critical,CA:TRUE \
  -addext keyUsage=critical,keyCertSign,cRLSign >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -noenc -sha256 \
  -keyout "$tls_dir/key.pem" -out "$tls_dir/request.pem" \
  -subj /CN=localhost -addext subjectAltName=DNS:localhost \
  -addext basicConstraints=critical,CA:FALSE \
  -addext keyUsage=critical,digitalSignature,keyEncipherment \
  -addext extendedKeyUsage=serverAuth >/dev/null 2>&1
openssl x509 -req -in "$tls_dir/request.pem" -CA "$tls_dir/ca.pem" \
  -CAkey "$tls_dir/ca-key.pem" -set_serial 1 -days 1 -sha256 \
  -copy_extensions copy -out "$tls_dir/cert.pem" >/dev/null 2>&1
openssl s_server -accept 127.0.0.1:44343 -cert "$tls_dir/cert.pem" \
  -key "$tls_dir/key.pem" -www -quiet > "$tls_dir/server.log" 2>&1 &
server_pid=$!
for attempt in $(seq 1 50); do
  if nc -z 127.0.0.1 44343; then
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null || [ "$attempt" = 50 ]; then
    echo 'isolated TLS smoke listener did not start' >&2
    exit 1
  fi
  sleep 0.1
done
/app/bin/emisar rpc "
  :ok = :ssl.start()
  true = length(:public_key.cacerts_get()) > 0
  true = byte_size(:crypto.strong_rand_bytes(32)) == 32
  {:ok, socket} = :ssl.connect({127, 0, 0, 1}, 44343,
    [active: false, verify: :verify_peer,
     cacertfile: ~c\"$tls_dir/ca.pem\",
     server_name_indication: ~c\"localhost\",
     customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]],
    5000)
  :ok = :ssl.close(socket)"
echo 'packaged SSL/crypto, system CA loading and verified TLS handshake passed'

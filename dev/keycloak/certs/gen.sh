#!/usr/bin/env bash
#
# Create the ignored DEV-ONLY CA + Keycloak server certificate used by both
# dev/compose.yml and the packaged root smoke stack. The default is idempotent;
# pass --rotate to intentionally replace the CA and every leaf it signed.
#
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
  "") ;;
  --rotate) rm -rf generated ;;
  *) echo "usage: $0 [--rotate]" >&2; exit 2 ;;
esac

out=generated
mkdir -p "$out"
chmod 700 "$out"

DAYS=3650
# Both the dynamic Coop sidecar and packaged smoke stack use localhost with a
# workspace-specific or fixed port. Loopback is the only identity verified by
# this certificate.
SAN="DNS:localhost,IP:127.0.0.1"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- CA ---------------------------------------------------------------------
# A well-formed CA cert needs basicConstraints CA:TRUE *and* keyUsage with
# keyCertSign — macOS LibreSSL / the keychain reject a CA that omits keyUsage.
cat >"$tmp/ca.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions    = v3_ca
prompt             = no
[dn]
CN = emisar dev CA
[v3_ca]
basicConstraints     = critical,CA:TRUE
keyUsage             = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF
if [[ ! -s "$out/ca.key" || ! -s "$out/ca.crt" ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$tmp/ca.key" -out "$tmp/ca.crt" -days "$DAYS" -config "$tmp/ca.cnf"
  install -m 600 "$tmp/ca.key" "$out/ca.key"
  install -m 644 "$tmp/ca.crt" "$out/ca.crt"
fi

# --- server cert (signed by the CA) -----------------------------------------
cat >"$tmp/srv.cnf" <<EOF
subjectAltName   = $SAN
basicConstraints = critical,CA:FALSE
keyUsage         = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
EOF
if [[ ! -s "$out/tls.key" || ! -s "$out/tls.crt" ]]; then
  openssl req -newkey rsa:2048 -nodes -keyout "$tmp/tls.key" \
    -out "$tmp/tls.csr" -subj "/CN=keycloak"
  openssl x509 -req -in "$tmp/tls.csr" -CA "$out/ca.crt" -CAkey "$out/ca.key" \
    -CAcreateserial -out "$tmp/tls.crt" -days "$DAYS" -extfile "$tmp/srv.cnf"
  install -m 600 "$tmp/tls.key" "$out/tls.key"
  install -m 644 "$tmp/tls.crt" "$out/tls.crt"
fi

openssl verify -CAfile "$out/ca.crt" "$out/tls.crt"
echo "✓ Keycloak dev certificates ready in $out/ (SAN: $SAN)"

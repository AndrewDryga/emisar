#!/usr/bin/env bash
#
# Regenerate the DEV-ONLY self-signed CA + Keycloak server cert for the
# docker-compose SSO stack (../../../docker-compose.yml). DEV ONLY — these are
# committed deliberately so the stack works out of the box; NEVER use them in
# production. Re-run after changing the SAN list, then restart keycloak + portal:
#
#   ./gen.sh && (cd ../../.. && docker compose up -d --force-recreate keycloak portal)
#
set -euo pipefail
cd "$(dirname "$0")"

DAYS=3650
# Every hostname the OIDC issuer is reached by: keycloak (docker DNS),
# localhost + 127.0.0.1 (host-published port), host.docker.internal (the host
# browser path — needs `127.0.0.1 host.docker.internal` in /etc/hosts).
SAN="DNS:keycloak,DNS:localhost,DNS:host.docker.internal,IP:127.0.0.1"

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
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/ca.key" -out ca.crt \
  -days "$DAYS" -config "$tmp/ca.cnf"

# --- server cert (signed by the CA) -----------------------------------------
cat >"$tmp/srv.cnf" <<EOF
subjectAltName   = $SAN
basicConstraints = critical,CA:FALSE
keyUsage         = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
EOF
openssl req -newkey rsa:2048 -nodes -keyout tls.key -out "$tmp/tls.csr" -subj "/CN=keycloak"
openssl x509 -req -in "$tmp/tls.csr" -CA ca.crt -CAkey "$tmp/ca.key" \
  -CAserial "$tmp/ca.srl" -CAcreateserial -out tls.crt -days "$DAYS" \
  -extfile "$tmp/srv.cnf"

chmod 600 tls.key
openssl verify -CAfile ca.crt tls.crt
echo "✓ regenerated ca.crt + tls.crt/tls.key (SAN: $SAN)"

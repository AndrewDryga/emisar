#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "::error::$*" >&2
  exit 1
}

key=${MCP_PRIVATE_KEY:-}
test -n "$key" || die "MCP_PRIVATE_KEY is not configured"

if [[ "$key" =~ ^[0-9a-fA-F]{64}$ ]]; then
  tr '[:upper:]' '[:lower:]' <<< "$key"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
umask 077
printf '%s\n' "$key" > "$tmp/private.pem"

openssl pkey -in "$tmp/private.pem" -outform DER -out "$tmp/private.der" 2>/dev/null || \
  die "MCP_PRIVATE_KEY must be a 64-character Ed25519 hex seed or a valid PEM private key"

seed=$(tail -c 32 "$tmp/private.der" | xxd -p -c 64)
[[ "$seed" =~ ^[0-9a-f]{64}$ ]] || die "could not extract a 32-byte Ed25519 seed from MCP_PRIVATE_KEY"
printf '%s\n' "$seed"

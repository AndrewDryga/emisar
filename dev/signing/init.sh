#!/bin/sh
# signing-init — mint the signed-dispatch e2e material at stack-up into the
# shared /signing volume. Generate-at-startup: no CA or leaf private key is ever
# committed to the repo. Idempotent — it reuses existing material so the running
# runner-signed keeps trusting the same CA; `docker compose down -v` rotates it.
#
# It writes three files the rest of the stack reads:
#   /signing/config.yaml   runner-signed's config (the mounted template with the
#                          freshly-minted CA public key substituted in)
#   /signing/leaf_key      EMISAR_SIGNING_KEY for the MCP bridge (the e2e reads it)
#   /signing/cert.json     EMISAR_SIGNING_CERT for the MCP bridge
#
# Parsing note: we read `emisar signing init`'s human output, whose CA public key,
# leaf seed, and cert each sit on a single labelled line — robust with grep/sed,
# so the minimal runner image needs no jq/python.
set -eu

OUT=/signing
TEMPLATE=/templates/signed-iad.yaml

if [ -s "$OUT/config.yaml" ] && [ -s "$OUT/leaf_key" ] && [ -s "$OUT/cert.json" ]; then
  echo "signing-init: material already present in $OUT — reusing (docker compose down -v to rotate)"
  exit 0
fi

echo "signing-init: minting CA + leaf + cert (emisar signing init, scope group=signed-iad)..."
material="$(emisar signing init --ca-id e2e-ca --scope group=signed-iad --ttl 1y)"

ca_pub="$(printf '%s\n' "$material" | grep 'public_key:' | head -n1 | sed 's/.*public_key:[[:space:]]*//')"
leaf="$(printf '%s\n' "$material" | grep 'EMISAR_SIGNING_KEY=' | sed 's/.*EMISAR_SIGNING_KEY=//')"
cert="$(printf '%s\n' "$material" | grep 'EMISAR_SIGNING_CERT=' | sed 's/.*EMISAR_SIGNING_CERT=//')"

# Fail closed if parsing drifted: a 64-char hex CA key, a non-empty leaf + cert.
case "$ca_pub" in
  "" | *[!0-9a-f]*)
    echo "signing-init: parsed CA public key looks wrong: '$ca_pub'" >&2
    exit 1
    ;;
esac
[ -n "$leaf" ] || { echo "signing-init: parsed an empty leaf key" >&2; exit 1; }
[ -n "$cert" ] || { echo "signing-init: parsed an empty cert" >&2; exit 1; }

printf '%s' "$leaf" >"$OUT/leaf_key"
printf '%s' "$cert" >"$OUT/cert.json"
sed "s|__CA_PUBLIC_KEY__|$ca_pub|" "$TEMPLATE" >"$OUT/config.yaml"

# World-readable so the non-root runner-signed (and the host e2e) can read them.
# DEV ONLY — these are throwaway keys in an ephemeral volume.
chmod 0644 "$OUT/config.yaml" "$OUT/leaf_key" "$OUT/cert.json"
echo "signing-init: wrote config.yaml, leaf_key, cert.json to $OUT (ca_id=e2e-ca, scope group=signed-iad)"

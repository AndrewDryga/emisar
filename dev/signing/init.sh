#!/bin/sh
# signing-init — mint the signed-dispatch e2e material at stack-up into the
# shared /signing volume. Generate-at-startup: no CA or leaf private key is ever
# committed to the repo. Idempotent within one certificate format; a format bump
# remints the throwaway trust chain so stale volume state cannot break the E2E.
#
# It writes four files the rest of the stack reads:
#   /signing/config.yaml   runner-signed's config (the mounted template with the
#                          freshly-minted CA certificate substituted in)
#   /signing/leaf_key      EMISAR_SIGNING_KEY for the MCP bridge (the e2e reads it)
#   /signing/cert_chain    EMISAR_SIGNING_CERT for the MCP bridge
#   /signing/format        certificate profile revision for stale-volume checks
#
# Parsing note: we read `emisar signing init --json`, whose output is pretty-
# printed one field per line, with the CA certificate carried as a single line of
# \n-escaped PEM. That is far steadier than scraping the human block, and it
# needs no jq or python in the minimal runner image.
set -eu

OUT=/signing
TEMPLATE=/templates/signed-iad.yaml
FORMAT=emisar-x509-profile-v1

if [ -s "$OUT/config.yaml" ] && [ -s "$OUT/leaf_key" ] && [ -s "$OUT/cert_chain" ] &&
  [ "$(cat "$OUT/format" 2>/dev/null || true)" = "$FORMAT" ]; then
  echo "signing-init: $FORMAT material already present in $OUT — reusing"
  exit 0
fi

echo "signing-init: minting CA + leaf + certificate (scope group=signed-iad)..."
material="$(emisar --json signing init --ca-name e2e-ca --scope group=signed-iad --ttl 1y)"

# One pretty-printed field per line: "key": "value",
json_field() {
  printf '%s\n' "$material" | grep "\"$1\":" | head -n1 |
    sed -e "s/^.*\"$1\": \"//" -e 's/",*$//'
}

ca_cert="$(json_field ca_certificate)"
leaf="$(json_field private_key)"
cert="$(json_field certificate_chain)"

# Fail closed if parsing drifted rather than writing material the runner would
# reject later with a refusal that points at the wrong thing.
case "$ca_cert" in
  *"BEGIN CERTIFICATE"*) ;;
  *)
    echo "signing-init: parsed CA certificate is not PEM: '$ca_cert'" >&2
    exit 1
    ;;
esac
[ -n "$leaf" ] || { echo "signing-init: parsed an empty leaf key" >&2; exit 1; }
[ -n "$cert" ] || { echo "signing-init: parsed an empty certificate chain" >&2; exit 1; }

printf '%s' "$leaf" >"$OUT/leaf_key"
printf '%s' "$cert" >"$OUT/cert_chain"

# The template carries __CA_PEM__ alone on a line, indented to where the PEM
# block belongs; replace that line with the certificate at the same indent.
# Match the placeholder LINE, never the prose that names it in the comment above.
placeholder='^[[:space:]]*__CA_PEM__[[:space:]]*$'
indent="$(grep -m1 "$placeholder" "$TEMPLATE" | sed 's/[^ ].*//')"
[ -n "$indent" ] || { echo "signing-init: no __CA_PEM__ placeholder line in $TEMPLATE" >&2; exit 1; }
ca_pem_block="$(printf '%b' "$ca_cert" | grep -v '^[[:space:]]*$' | sed "s/^/$indent/")"

{
  while IFS= read -r line; do
    if printf '%s' "$line" | grep -q "$placeholder"; then
      printf '%s\n' "$ca_pem_block"
    else
      printf '%s\n' "$line"
    fi
  done <"$TEMPLATE"
} >"$OUT/config.yaml"

printf '%s' "$FORMAT" >"$OUT/format"

# World-readable so the non-root runner-signed (and the host e2e) can read them.
# DEV ONLY — these are throwaway keys in an ephemeral volume.
chmod 0644 "$OUT/config.yaml" "$OUT/leaf_key" "$OUT/cert_chain" "$OUT/format"
echo "signing-init: wrote config.yaml, leaf_key, cert_chain to $OUT (ca=e2e-ca, scope group=signed-iad)"

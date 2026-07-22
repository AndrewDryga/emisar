#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
TMP=$(mktemp -d)
PROBE="$ROOT/portal/apps/emisar_web/lib/emisar_web/zz_dev_run_probe_${RANDOM}_$$.ex"
PROBE_CREATED=0
cleanup() {
  rm -rf "$TMP"
  [[ $PROBE_CREATED -eq 0 ]] || rm -f "$PROBE"
}
trap cleanup EXIT

fail() {
  echo "dev/run_test.sh: $*" >&2
  exit 1
}

mkdir -p "$TMP/certs" "$TMP/bin"
cp "$ROOT/dev/keycloak/certs/gen.sh" "$TMP/certs/gen.sh"
chmod +x "$TMP/certs/gen.sh"

"$TMP/certs/gen.sh" >/dev/null 2>&1
ca_before=$(openssl x509 -in "$TMP/certs/generated/ca.crt" -noout -fingerprint -sha256)
leaf_before=$(openssl x509 -in "$TMP/certs/generated/tls.crt" -noout -fingerprint -sha256)
openssl verify -CAfile "$TMP/certs/generated/ca.crt" "$TMP/certs/generated/tls.crt" >/dev/null
openssl x509 -in "$TMP/certs/generated/tls.crt" -checkend $((396 * 86400)) -noout >/dev/null
if openssl x509 -in "$TMP/certs/generated/tls.crt" -checkend $((398 * 86400)) -noout >/dev/null; then
  fail "Keycloak leaf validity exceeds the macOS browser limit"
fi

"$TMP/certs/gen.sh" >/dev/null 2>&1
[[ "$(openssl x509 -in "$TMP/certs/generated/ca.crt" -noout -fingerprint -sha256)" == "$ca_before" ]] ||
  fail "idempotent generation changed the CA"
[[ "$(openssl x509 -in "$TMP/certs/generated/tls.crt" -noout -fingerprint -sha256)" == "$leaf_before" ]] ||
  fail "idempotent generation changed the leaf"

"$TMP/certs/gen.sh" --rotate >/dev/null 2>&1
ca_rotated=$(openssl x509 -in "$TMP/certs/generated/ca.crt" -noout -fingerprint -sha256)
leaf_rotated=$(openssl x509 -in "$TMP/certs/generated/tls.crt" -noout -fingerprint -sha256)
[[ "$ca_rotated" != "$ca_before" ]] ||
  fail "intentional rotation kept the old CA"
[[ "$leaf_rotated" != "$leaf_before" ]] ||
  fail "intentional rotation kept the old leaf"

rm -f "$TMP/certs/generated/ca.key" "$TMP/certs/generated/ca.crt"
"$TMP/certs/gen.sh" >/dev/null 2>&1
[[ "$(openssl x509 -in "$TMP/certs/generated/ca.crt" -noout -fingerprint -sha256)" != "$ca_rotated" ]] ||
  fail "generation did not replace missing CA material"
[[ "$(openssl x509 -in "$TMP/certs/generated/tls.crt" -noout -fingerprint -sha256)" != "$leaf_rotated" ]] ||
  fail "generation kept a leaf signed by the missing CA"
openssl verify -CAfile "$TMP/certs/generated/ca.crt" "$TMP/certs/generated/tls.crt" >/dev/null

[[ ! -e "$PROBE" ]] || fail "$PROBE already exists"
printf 'defmodule EmisarWeb.DevRunProbe do\nend\n' >"$PROBE"
PROBE_CREATED=1
cat >"$TMP/bin/mix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DEV_RUN_TEST_LOG"
EOF
cat >"$TMP/bin/coop" <<'EOF'
#!/usr/bin/env bash
echo "coop must not run during check changed" >&2
exit 97
EOF
chmod +x "$TMP/bin/mix" "$TMP/bin/coop"

DEV_RUN_TEST_LOG="$TMP/mix.log" PATH="$TMP/bin:$PATH" "$ROOT/dev/run" check changed >/dev/null
grep -Fxq 'compile --warnings-as-errors' "$TMP/mix.log" || fail "changed check skipped incremental compile"
grep -Fq 'format --check-formatted' "$TMP/mix.log" || fail "changed check skipped format"
probe_relative=${PROBE#"$ROOT/portal/"}
grep -Fq "$probe_relative" "$TMP/mix.log" ||
  fail "changed check did not select the untracked Portal source"
grep -F 'credo ' "$TMP/mix.log" | grep -Fq "$probe_relative" ||
  fail "changed check skipped focused Credo"

echo "✓ dev/run changed feedback and certificate generation tests passed"

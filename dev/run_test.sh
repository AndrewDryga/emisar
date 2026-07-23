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

DEV_RUN_FUNCTIONS="$TMP/dev-run-functions"
awk '/^cmd=/{exit} {print}' "$ROOT/dev/run" >"$DEV_RUN_FUNCTIONS"

test_active_serve_owner() {
  local TMPDIR="$TMP/runtime-active" XDG_RUNTIME_DIR=""
  export TMPDIR XDG_RUNTIME_DIR
  # shellcheck disable=SC1090
  source "$DEV_RUN_FUNCTIONS"
  claim_serve 43123 "http://localhost:43123"
  owner_pid=$(sed -n '1p' "$SERVE_OWNER_DIR/pid")
  [[ "$owner_pid" == "$$" ]] || fail "serve ownership recorded the wrong PID"

  set +e
  owner_error=$(claim_serve 43123 "http://localhost:43123" 2>&1)
  owner_status=$?
  set -e
  [[ $owner_status -ne 0 ]] || fail "a second serve process claimed an active workspace"
  [[ "$owner_error" == *"pid $owner_pid"* ]] || fail "active serve error omitted the owner PID"
  [[ "$owner_error" != *"Waiting for lock"* ]] || fail "active serve reached Mix's build lock"

  release_serve
  [[ ! -e "$(serve_owner_path 43123)" ]] || fail "serve ownership survived clean release"
}

test_stale_serve_owner() {
  local TMPDIR="$TMP/runtime-stale" XDG_RUNTIME_DIR="" stale_owner
  export TMPDIR XDG_RUNTIME_DIR
  # shellcheck disable=SC1090
  source "$DEV_RUN_FUNCTIONS"
  stale_owner=$(serve_owner_path 43124)
  mkdir -p "$stale_owner"
  printf '99999999\n' >"$stale_owner/pid"
  claim_serve 43124 "http://localhost:43124"
  [[ "$(sed -n '1p' "$SERVE_OWNER_DIR/pid")" == "$$" ]] ||
    fail "serve did not replace stale ownership"
  release_serve
}

test_active_serve_owner
test_stale_serve_owner

PACK_ROOT="$TMP/pack-repo"
mkdir -p \
  "$PACK_ROOT/dev" \
  "$PACK_ROOT/dist/packs/stale" \
  "$PACK_ROOT/dist/x-ads" \
  "$PACK_ROOT/packs/example" \
  "$PACK_ROOT/portal/apps/emisar" \
  "$PACK_ROOT/portal/apps/emisar/priv/packs" \
  "$PACK_ROOT/portal/apps/emisar_web" \
  "$PACK_ROOT/runner"
git init -q "$PACK_ROOT"
cp "$ROOT/dev/run" "$PACK_ROOT/dev/run"
chmod +x "$PACK_ROOT/dev/run"
printf 'keep\n' >"$PACK_ROOT/dist/x-ads/keep.png"
printf 'stale\n' >"$PACK_ROOT/dist/packs/stale/file"

cat >"$TMP/bin/go" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$(dirname "$out")"
if [[ "$(basename "$out")" == packctl ]]; then
  cat >"$out" <<'PACKCTL'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$out/v1"
printf '{"schema_version":1,"packs":[]}\n' >"$out/v1/catalog.json"
PACKCTL
else
  printf '#!/usr/bin/env bash\nexit 0\n' >"$out"
fi
chmod +x "$out"
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '{"schema_version":1,"packs":[]}\n' >"$out"
EOF
cat >"$TMP/bin/mix" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/go" "$TMP/bin/curl" "$TMP/bin/mix"

PATH="$TMP/bin:$PATH" "$PACK_ROOT/dev/run" pack sync example --fix >/dev/null
[[ -f "$PACK_ROOT/dist/x-ads/keep.png" ]] || fail "pack sync deleted a sibling dist artifact"
[[ ! -e "$PACK_ROOT/dist/packs/stale/file" ]] || fail "pack sync kept stale pack output"
cmp "$PACK_ROOT/dist/packs/v1/catalog.json" \
  "$PACK_ROOT/portal/apps/emisar/priv/packs/catalog.json" >/dev/null ||
  fail "pack sync did not copy the generated versioned catalog"

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

echo "✓ dev/run behavior and certificate generation tests passed"

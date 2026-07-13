#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
check="$root/.github/scripts/check-attest-parity.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/mcp/internal" "$tmp/runner/internal"
cp -R "$root/mcp/internal/attest" "$tmp/mcp/internal/attest"
cp -R "$root/runner/internal/attest" "$tmp/runner/internal/attest"

run_check() {
  EMISAR_ATTEST_ROOT="$tmp" "$check" >/dev/null 2>&1
}

run_check

# Guards that exercise only one module are intentionally allowed outside the
# shared constants/vector functions.
printf '\nfunc moduleSpecificParityFixture() {}\n' >> "$tmp/runner/internal/attest/attest_test.go"
run_check

printf '\n// one-sided implementation drift\n' >> "$tmp/runner/internal/attest/attest.go"
if run_check; then
  echo "attestation parity check accepted one-sided implementation drift" >&2
  exit 1
fi
cp "$tmp/mcp/internal/attest/attest.go" "$tmp/runner/internal/attest/attest.go"

awk '
  !changed && /vectorSeedHex/ { sub(/1f20"/, "1f21\""); changed = 1 }
  { print }
' "$tmp/runner/internal/attest/attest_test.go" > "$tmp/runner/internal/attest/attest_test.go.next"
mv "$tmp/runner/internal/attest/attest_test.go.next" "$tmp/runner/internal/attest/attest_test.go"

if run_check; then
  echo "attestation parity check accepted one-sided fixed-vector drift" >&2
  exit 1
fi

echo "ok: attestation parity guard rejects one-sided drift"

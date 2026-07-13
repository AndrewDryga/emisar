#!/usr/bin/env bash
set -euo pipefail

root=${EMISAR_ATTEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
mcp="$root/mcp/internal/attest"
runner="$root/runner/internal/attest"

if ! cmp -s "$mcp/attest.go" "$runner/attest.go"; then
  echo "attestation implementations differ; update mcp and runner together" >&2
  diff -u "$mcp/attest.go" "$runner/attest.go" || true
  exit 1
fi

extract_vectors() {
  sed -n \
    -e '/^const (/,/^)/p' \
    -e '/^func vectorClaims()/,/^}$/p' \
    -e '/^func vectorCerts()/,/^}$/p' \
    "$1"
}

for test_file in "$mcp/attest_test.go" "$runner/attest_test.go"; do
  vectors=$(extract_vectors "$test_file")
  if ! grep -q 'name:  "empty args"' <<<"$vectors" ||
    ! grep -q 'name:  "empty scope (any runner)"' <<<"$vectors"; then
    echo "failed to extract complete attestation vectors from $test_file" >&2
    exit 1
  fi
done

if ! diff -u \
  <(extract_vectors "$mcp/attest_test.go") \
  <(extract_vectors "$runner/attest_test.go"); then
  echo "attestation fixed vectors differ; update mcp and runner together" >&2
  exit 1
fi

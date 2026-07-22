#!/usr/bin/env bash
set -euo pipefail

destination=${1:-./mcp-publisher}
version=1.8.0
sha256=1370446bbe74d562608e8005a6ccce02d146a661fbd78674e11cc70b9618d6cf
artifact=mcp-publisher_linux_amd64.tar.gz
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
  "https://github.com/modelcontextprotocol/registry/releases/download/v${version}/${artifact}" \
  --output "$tmp/$artifact"
printf '%s  %s\n' "$sha256" "$tmp/$artifact" | shasum -a 256 --check --
tar --extract --gzip --file "$tmp/$artifact" --directory "$tmp" mcp-publisher
install -m 0755 "$tmp/mcp-publisher" "$destination"

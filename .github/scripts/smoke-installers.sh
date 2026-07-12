#!/usr/bin/env bash
set -euo pipefail

module=${1:?usage: smoke-installers.sh runner|mcp}
if [ "$module" = runner ] && [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$module"
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

case "$module" in
  runner)
    EMISAR_PACKS="" bash install.sh --yes --no-service \
      --version runner-v0.9.1 \
      --bin-dir "$tmp/bin" \
      --etc-dir "$tmp/etc" \
      --data-dir "$tmp/data" \
      --log-dir "$tmp/log" >/dev/null
    test "$("$tmp/bin/emisar" --version)" = "emisar version 0.9.1"

    before=$(sha256 "$tmp/bin/emisar")
    mkdir -p "$tmp/bad-etc/config.yaml"
    if EMISAR_PACKS="" bash install.sh --yes --no-service \
      --version runner-v0.9.1 \
      --bin-dir "$tmp/bin" \
      --etc-dir "$tmp/bad-etc" \
      --data-dir "$tmp/data" \
      --log-dir "$tmp/log" >"$tmp/failure.log" 2>&1; then
      echo "runner installer failure injection unexpectedly succeeded" >&2
      exit 1
    fi
    after=$(sha256 "$tmp/bin/emisar")
    test "$before" = "$after"
    grep -Fq "restored previous binary after failed upgrade" "$tmp/failure.log"
    ;;
  mcp)
    bash install-mcp.sh --yes --version mcp-v0.2.1 --install-dir "$tmp/bin" >/dev/null
    test "$("$tmp/bin/emisar-mcp" --version)" = "emisar-mcp 0.2.1"
    ;;
  *)
    echo "unknown installer module: $module" >&2
    exit 2
    ;;
esac

echo "ok: ${module} installer smoke test passed"

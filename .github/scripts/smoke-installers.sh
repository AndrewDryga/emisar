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

extract_launchd_runner() {
  awk '
    /^launchd_runner_script\(\) \{/ { in_function = 1; next }
    in_function && /^  cat <<'\''LAUNCHD_RUNNER'\''$/ { copying = 1; next }
    copying && /^LAUNCHD_RUNNER$/ { exit }
    copying { print }
  ' install.sh
}

case "$module" in
  runner)
    EMISAR_PACKS="" bash install.sh --yes --no-service \
      --bin-dir "$tmp/bin" \
      --etc-dir "$tmp/etc" \
      --data-dir "$tmp/data" \
      --log-dir "$tmp/log" >/dev/null
    installed=$("$tmp/bin/emisar" --version)
    [[ "$installed" =~ ^emisar\ version\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
    version=${installed#emisar version }

    before=$(sha256 "$tmp/bin/emisar")
    mkdir -p "$tmp/bad-etc/config.yaml"
    if EMISAR_PACKS="" bash install.sh --yes --no-service \
      --version "runner-v${version}" \
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

    # launchd has no EnvironmentFile directive. Execute the exact wrapper
    # embedded in install.sh and prove it exports runner.env before replacing
    # itself with the runner, while preserving a config path with spaces.
    launchd_runner="$tmp/run-launchd.sh"
    extract_launchd_runner >"$launchd_runner"
    chmod +x "$launchd_runner"
    cat >"$tmp/fake-emisar" <<'FAKE_RUNNER'
#!/bin/sh
set -eu
printf '%s\n' "$EMISAR_SMOKE_SECRET" "$@" >"$EMISAR_SMOKE_OUTPUT"
FAKE_RUNNER
    chmod +x "$tmp/fake-emisar"
    printf 'EMISAR_SMOKE_SECRET=loaded\nEMISAR_SMOKE_OUTPUT=%s\n' "$tmp/launchd.out" \
      >"$tmp/runner.env"
    config="$tmp/config path.yaml"
    : >"$config"
    "$launchd_runner" "$tmp/fake-emisar" "$config" "$tmp/runner.env"
    printf 'loaded\n--config\n%s\nconnect\n' "$config" >"$tmp/launchd.want"
    diff -u "$tmp/launchd.want" "$tmp/launchd.out"
    ;;
  mcp)
    bash install-mcp.sh --yes --install-dir "$tmp/bin" >/dev/null
    installed=$("$tmp/bin/emisar-mcp" --version)
    [[ "$installed" =~ ^emisar-mcp\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
    version=${installed#emisar-mcp }

    for flag in --version --install-dir; do
      set +e
      output=$(bash install-mcp.sh "$flag" 2>&1)
      status=$?
      set -e
      test "$status" -eq 2
      grep -Fq "flag ${flag} requires a value" <<<"$output"
      grep -Fq "Usage: install-mcp.sh" <<<"$output"
    done

    set +e
    output=$(bash install-mcp.sh --version --yes 2>&1)
    status=$?
    set -e
    test "$status" -eq 2
    grep -Fq "flag --version requires a value" <<<"$output"

    real_mv=$(command -v mv)
    mkdir -p "$tmp/fake-bin"
    printf "#!/usr/bin/env bash\nset -e\n\"%s\" \"\$@\"\nkill -KILL \"\$PPID\"\n" "$real_mv" \
      >"$tmp/fake-bin/mv"
    chmod +x "$tmp/fake-bin/mv"

    set +e
    PATH="$tmp/fake-bin:$PATH" bash install-mcp.sh --yes \
      --version "mcp-v${version}" --install-dir "$tmp/bin" \
      >"$tmp/interrupted-upgrade.log" 2>&1
    status=$?
    set -e
    test "$status" -ne 0
    test -x "$tmp/bin/emisar-mcp"
    test "$("$tmp/bin/emisar-mcp" --version)" = "$installed"
    ;;
  *)
    echo "unknown installer module: $module" >&2
    exit 2
    ;;
esac

echo "ok: ${module} installer smoke test passed"

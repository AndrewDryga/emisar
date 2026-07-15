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

extract_shell_function() {
  local file="$1" name="$2"
  awk -v signature="${name}() {" '
    $0 == signature { copying = 1 }
    copying { print }
    copying && /^}$/ { exit }
  ' "$file"
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

    # A repeat service upgrade must never hand root-owned admission/signing
    # config to the runner account. Exercise the exact directory helper in
    # isolation so the test is independent of the host init system.
    if [ "$(id -u)" -eq 0 ]; then
      ensure_dirs_lib="$tmp/ensure-dirs.sh"
      extract_shell_function install.sh ensure_dirs >"$ensure_dirs_lib"
      mkdir -p "$tmp/service-etc" "$tmp/service-data" "$tmp/service-log"
      printf 'signing:\n  enforce: true\n' >"$tmp/service-etc/config.yaml"
      chown root:root "$tmp/service-etc/config.yaml"
      (
        # shellcheck disable=SC1090
        source "$ensure_dirs_lib"
        log() { :; }
        log ""
        export SERVICE_USER=nobody
        export SERVICE_GROUP
        SERVICE_GROUP=$(id -gn nobody)
        export OS=linux
        export INIT=systemd
        export ETC_DIR="$tmp/service-etc"
        export DATA_DIR="$tmp/service-data"
        export LOG_DIR="$tmp/service-log"
        ensure_dirs
      )
      test "$(stat -c %U "$tmp/service-etc/config.yaml")" = root
    fi
    ;;
  mcp)
    resolve_dirs_lib="$tmp/resolve-install-dirs.sh"
    extract_shell_function install-mcp.sh resolve_install_dirs >"$resolve_dirs_lib"
    # shellcheck disable=SC1090
    source "$resolve_dirs_lib"
    mkdir -p "$tmp/home/.local/bin" "$tmp/system-bin"
    : >"$tmp/home/.local/bin/emisar-mcp"
    : >"$tmp/system-bin/emisar-mcp"
    chmod +x "$tmp/home/.local/bin/emisar-mcp" "$tmp/system-bin/emisar-mcp"
    printf '%s\n%s\n' "$tmp/home/.local/bin" "$tmp/system-bin" >"$tmp/dirs.want"
    resolve_install_dirs "$tmp/home" "$tmp/system-bin" >"$tmp/dirs.got"
    diff -u "$tmp/dirs.want" "$tmp/dirs.got"

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

    credential_state="$tmp/home/.config/emisar/mcp-credentials.json"
    mkdir -p "$(dirname "$credential_state")"
    printf '{"bootstrap":{"api_key":"preserve-me"}}\n' >"$credential_state"
    credential_hash=$(sha256 "$credential_state")

    cat >"$tmp/bin/emisar-mcp" <<'OLD_MCP'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'emisar-mcp 0.0.0\n'
fi
OLD_MCP
    chmod +x "$tmp/bin/emisar-mcp"

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
    test "$(sha256 "$credential_state")" = "$credential_hash"

    # A privileged install must never execute a staged file in a destination
    # that the invoking user can replace. Substitute a hostile `install` that
    # writes an executable payload; digest verification must reject it without
    # running it.
    mkdir -p "$tmp/hostile-bin" "$tmp/hostile-target"
    real_install=$(command -v install)
    cat >"$tmp/hostile-bin/install" <<HOSTILE_INSTALL
#!/usr/bin/env bash
set -e
"${real_install}" "\$@"
cat >"\${!#}" <<'HOSTILE_PAYLOAD'
#!/usr/bin/env bash
touch "${tmp}/hostile-executed"
printf 'emisar-mcp %s\n' "${version}"
HOSTILE_PAYLOAD
chmod +x "\${!#}"
HOSTILE_INSTALL
    chmod +x "$tmp/hostile-bin/install"

    set +e
    PATH="$tmp/hostile-bin:$PATH" bash install-mcp.sh --yes \
      --version "mcp-v${version}" --install-dir "$tmp/hostile-target" \
      >"$tmp/hostile-stage.log" 2>&1
    status=$?
    set -e
    test "$status" -ne 0
    test ! -e "$tmp/hostile-executed"
    grep -Fq "staged binary checksum changed" "$tmp/hostile-stage.log"
    ;;
  *)
    echo "unknown installer module: $module" >&2
    exit 2
    ;;
esac

echo "ok: ${module} installer smoke test passed"

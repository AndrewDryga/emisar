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
      extract_shell_function install.sh secure_pack_tree >"$tmp/secure-pack-tree.sh"
      mkdir -p "$tmp/service-etc" "$tmp/service-data" "$tmp/service-log"
      printf 'signing:\n  enforce: true\n' >"$tmp/service-etc/config.yaml"
      chown root:root "$tmp/service-etc/config.yaml"
      mkdir -p "$tmp/service-etc/packs/test/actions"
      : >"$tmp/service-etc/packs/test/pack.yaml"
      chown -R nobody:"$(id -gn nobody)" "$tmp/service-etc/packs"
      (
        # shellcheck disable=SC1090
        source "$ensure_dirs_lib"
        # shellcheck disable=SC1090,SC1091
        source "$tmp/secure-pack-tree.sh"
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
        secure_pack_tree
      )
      test "$(stat -c %U "$tmp/service-etc/config.yaml")" = root
      test "$(stat -c %U "$tmp/service-etc/packs/test/pack.yaml")" = root
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

    # A sudo invocation must ignore an inherited TMPDIR. The downloaded binary
    # is executed for its version, so its parent must not be replaceable by the
    # invoking user.
    trusted_tmp_lib="$tmp/trusted-temp.sh"
    extract_shell_function install-mcp.sh make_temp_dir >"$trusted_tmp_lib"
    printf 'make_temp_dir\n' >>"$trusted_tmp_lib"
    mkdir -p "$tmp/user-controlled-tmp"
    if [ "$(id -u)" -eq 0 ]; then
      trusted_tmp=$(TMPDIR="$tmp/user-controlled-tmp" bash "$trusted_tmp_lib")
      case "$trusted_tmp" in
        /tmp/emisar-mcp-install.*) ;;
        *) echo "privileged temporary directory was not rooted in /tmp: $trusted_tmp" >&2; exit 1;;
      esac
      rm -rf "$trusted_tmp"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      trusted_tmp=$(sudo -n env TMPDIR="$tmp/user-controlled-tmp" bash "$trusted_tmp_lib")
      case "$trusted_tmp" in
        /tmp/emisar-mcp-install.*) ;;
        *) echo "privileged temporary directory was not rooted in /tmp: $trusted_tmp" >&2; exit 1;;
      esac
      sudo -n rm -rf "$trusted_tmp"
    fi

    # Exercise the exact activation transaction with two client locations. A
    # failure on the second rename must restore the first location too.
    transaction_lib="$tmp/install-transaction.sh"
    extract_shell_function install-mcp.sh rollback_installations >"$transaction_lib"
    extract_shell_function install-mcp.sh activate_installations >>"$transaction_lib"
    # shellcheck disable=SC1090
    source "$transaction_lib"
    warn() { printf '%s\n' "$*" >&2; }
    sha_value() { sha256 "$1"; }

    link_target="$tmp/link-target"
    link_dir="$tmp/link-dir"
    mkdir -p "$link_dir"
    printf 'linked-old\n' >"$link_target"
    ln -s "$link_target" "$link_dir/emisar-mcp"
    printf 'new\n' >"$link_dir/.emisar-mcp.new.$$"
    install_dirs="$link_dir"
    staged_paths="$link_dir/.emisar-mcp.new.$$"
    source_sha=$(sha256 "$link_dir/.emisar-mcp.new.$$")
    backup_paths=""
    activated_paths=""
    installed_paths=""
    transaction_active=0
    export install_dirs staged_paths source_sha backup_paths activated_paths installed_paths transaction_active
    if activate_installations 2>"$tmp/symlink-denial.log"; then
      echo "symlink destination was unexpectedly replaced" >&2
      exit 1
    fi
    test -L "$link_dir/emisar-mcp"
    test "$(cat "$link_target")" = linked-old
    grep -Fq "is not a regular file; refusing to replace it" "$tmp/symlink-denial.log"

    tx_a="$tmp/tx-a"
    tx_b="$tmp/tx-b"
    mkdir -p "$tx_a" "$tx_b"
    printf 'old-a\n' >"$tx_a/emisar-mcp"
    printf 'old-b\n' >"$tx_b/emisar-mcp"
    printf 'new\n' >"$tx_a/.emisar-mcp.new.$$"
    printf 'new\n' >"$tx_b/.emisar-mcp.new.$$"
    install_dirs=$(printf '%s\n%s\n' "$tx_a" "$tx_b")
    staged_paths=$(printf '%s\n%s\n' \
      "$tx_a/.emisar-mcp.new.$$" "$tx_b/.emisar-mcp.new.$$")
    source_sha=$(sha256 "$tx_a/.emisar-mcp.new.$$")
    backup_paths=""
    activated_paths=""
    installed_paths=""
    transaction_active=0
    export install_dirs staged_paths source_sha backup_paths activated_paths installed_paths transaction_active

    mkdir -p "$tmp/failing-mv"
    real_mv=$(command -v mv)
    cat >"$tmp/failing-mv/mv" <<FAILING_MV
#!/usr/bin/env bash
set -e
src="\${@: -2:1}"
if [[ "\$src" == */.emisar-mcp.new.* ]]; then
  count=0
  test ! -e "$tmp/mv-count" || read -r count <"$tmp/mv-count"
  count=\$((count + 1))
  printf '%s\n' "\$count" >"$tmp/mv-count"
  if [ "\$count" -eq 2 ]; then
    exit 1
  fi
fi
exec "$real_mv" "\$@"
FAILING_MV
    chmod +x "$tmp/failing-mv/mv"

    if PATH="$tmp/failing-mv:$PATH" activate_installations 2>"$tmp/rollback.log"; then
      echo "two-target failure injection unexpectedly succeeded" >&2
      exit 1
    fi
    set +e
    PATH="$tmp/failing-mv:$PATH" rollback_installations 2>>"$tmp/rollback.log"
    rollback_status=$?
    set -e
    if [ "$rollback_status" -ne 0 ]; then
      cat "$tmp/rollback.log" >&2
      echo "two-target rollback failed" >&2
      exit 1
    fi
    test "$(cat "$tx_a/emisar-mcp")" = old-a
    test "$(cat "$tx_b/emisar-mcp")" = old-b
    test "$transaction_active" -eq 0
    grep -Fq "could not atomically activate $tx_b/emisar-mcp" "$tmp/rollback.log"

    while IFS= read -r path; do
      test -z "$path" || rm -f "$path"
    done <<<"$backup_paths"
    rm -f "$tx_a/.emisar-mcp.new.$$" "$tx_b/.emisar-mcp.new.$$"
    printf 'new\n' >"$tx_a/.emisar-mcp.new.$$"
    printf 'new\n' >"$tx_b/.emisar-mcp.new.$$"
    staged_paths=$(printf '%s\n%s\n' \
      "$tx_a/.emisar-mcp.new.$$" "$tx_b/.emisar-mcp.new.$$")
    source_sha=$(sha256 "$tx_a/.emisar-mcp.new.$$")
    backup_paths=""
    activated_paths=""
    installed_paths=""
    transaction_active=0
    export install_dirs staged_paths source_sha backup_paths activated_paths installed_paths transaction_active
    activate_installations
    test "$(cat "$tx_a/emisar-mcp")" = new
    test "$(cat "$tx_b/emisar-mcp")" = new
    test "$installed_paths" = "$(printf '%s\n%s' "$tx_a/emisar-mcp" "$tx_b/emisar-mcp")"
    test -z "$(find "$tx_a" "$tx_b" -name '.emisar-mcp.old.*' -print)"
    ;;
  *)
    echo "unknown installer module: $module" >&2
    exit 2
    ;;
esac

echo "ok: ${module} installer smoke test passed"

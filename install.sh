#!/usr/bin/env bash
#
# emisar installer.
#
# Reliable cross-OS installer for the emisar local runner. Handles:
#
#   * Linux + systemd  — production target. Creates a system user,
#     drops the binary in /usr/local/bin, installs a hardened
#     `emisar.service` unit, and uses systemd Restart=on-failure for
#     supervision.
#
#   * macOS + launchd  — dev/eval target. Installs the binary in
#     /usr/local/bin and a LaunchDaemon plist at
#     /Library/LaunchDaemons/com.emisar.runner.plist. KeepAlive +
#     ThrottleInterval handle supervision.
#
# Usage:
#
#   curl -sSL https://raw.githubusercontent.com/andrewdryga/emisar/main/install.sh | sudo bash
#
#   # Pin a specific runner version (tag, with or without prefix):
#   curl -sSL https://.../install.sh | sudo bash -s -- --version runner-v0.3.0
#   curl -sSL https://.../install.sh | sudo bash -s -- --version 0.3.0
#
#   # Uninstall:
#   sudo bash install.sh --uninstall
#
# Idempotent: re-running upgrades in place. Safe to interrupt — every
# step has explicit success criteria; nothing partially applied is left
# in a "running but broken" state.

set -euo pipefail

# -----------------------------------------------------------------------
# Configuration (env or flags)
# -----------------------------------------------------------------------

REPO="${EMISAR_REPO:-andrewdryga/emisar}"
VERSION="${VERSION:-}"            # empty = latest stable
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
ETC_DIR="${ETC_DIR:-/etc/emisar}"
DATA_DIR="${DATA_DIR:-/var/lib/emisar}"
LOG_DIR="${LOG_DIR:-/var/log/emisar}"
SERVICE_USER="${SERVICE_USER:-emisar}"
SERVICE_GROUP="${SERVICE_GROUP:-emisar}"
ASSUME_YES="${ASSUME_YES:-0}"
NO_START="${NO_START:-0}"
MODE="install"                    # install|uninstall

usage() {
  cat <<'USAGE'
emisar installer

Usage: install.sh [--version TAG] [--uninstall] [--no-start] [--yes]

Flags:
  --version TAG      Install a specific runner release tag. Default: latest.
                     Accepts `runner-vX.Y.Z`, `vX.Y.Z`, or bare `X.Y.Z`
                     (bare/v-prefixed forms are auto-prefixed with `runner-v`).
  --uninstall        Stop the service, remove binary + service unit.
                     Keeps /etc/emisar and /var/lib/emisar by default
                     (use --purge to remove those too).
  --purge            With --uninstall, also delete config + data + logs.
  --no-start         Install + enable the service but don't start it.
  --bin-dir DIR      Install path for the binary (default /usr/local/bin)
  --etc-dir DIR      Config dir (default /etc/emisar)
  --data-dir DIR     Data dir (default /var/lib/emisar)
  --log-dir DIR      Log dir (default /var/log/emisar)
  --user NAME        Service user (default emisar)
  --yes              Skip confirmation prompts.
  --help             This message.

Env vars accepted: VERSION, BIN_DIR, ETC_DIR, DATA_DIR, LOG_DIR,
SERVICE_USER, SERVICE_GROUP, ASSUME_YES, NO_START, EMISAR_REPO.
USAGE
}

# Normalize --version into the canonical `runner-vX.Y.Z` shape so
# `download_release` doesn't have to. Accepts:
#   runner-v0.3.0  → runner-v0.3.0  (verbatim)
#   v0.3.0         → runner-v0.3.0
#   0.3.0          → runner-v0.3.0
normalize_version() {
  case "$1" in
    runner-v*) printf '%s\n' "$1";;
    v*)        printf 'runner-%s\n' "$1";;
    *)         printf 'runner-v%s\n' "$1";;
  esac
}

PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$(normalize_version "$2")"; shift 2;;
    --uninstall) MODE="uninstall"; shift;;
    --purge) PURGE=1; shift;;
    --no-start) NO_START=1; shift;;
    --bin-dir) BIN_DIR="$2"; shift 2;;
    --etc-dir) ETC_DIR="$2"; shift 2;;
    --data-dir) DATA_DIR="$2"; shift 2;;
    --log-dir) LOG_DIR="$2"; shift 2;;
    --user) SERVICE_USER="$2"; SERVICE_GROUP="$2"; shift 2;;
    --yes|-y) ASSUME_YES=1; shift;;
    --help|-h) usage; exit 0;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2;;
  esac
done

# -----------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------

log()   { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; exit 1; }
confirm() {
  if [ "$ASSUME_YES" = "1" ]; then return 0; fi

  # `curl | bash` makes stdin the script content, not a terminal — so a
  # plain `read` consumes the NEXT LINE of the script and reports an
  # "empty" answer to every prompt. Try /dev/tty so the operator can
  # actually answer; if no controlling terminal exists at all (CI,
  # cloud-init, container provisioner) auto-yes — at that point the
  # caller explicitly opted in by running with sudo + env vars and
  # there's no human at the keyboard to confirm anyway.
  if [ -t 0 ]; then
    printf '%s [y/N] ' "$1"
    read -r reply || reply=""
  elif { exec 3</dev/tty; } 2>/dev/null; then
    printf '%s [y/N] ' "$1" >/dev/tty
    read -r reply <&3 || reply=""
    exec 3<&-
  else
    # No tty at all — treat as a non-interactive install. The caller
    # already opted in by piping us through `sudo bash`.
    return 0
  fi
  case "$reply" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac
}

# -----------------------------------------------------------------------
# Detect OS + arch + init system
# -----------------------------------------------------------------------

detect_os() {
  case "$(uname -s)" in
    Linux)  echo linux;;
    Darwin) echo darwin;;
    *) die "unsupported OS: $(uname -s)";;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64;;
    arm64|aarch64) echo arm64;;
    *) die "unsupported architecture: $(uname -m)";;
  esac
}

detect_init() {
  case "$(detect_os)" in
    linux)
      if command -v systemctl >/dev/null 2>&1; then
        echo systemd
      else
        die "this installer requires systemd on Linux (found: $(uname -a))"
      fi
      ;;
    darwin)
      if command -v launchctl >/dev/null 2>&1; then
        echo launchd
      else
        die "launchctl not found — macOS install requires launchd"
      fi
      ;;
  esac
}

OS="$(detect_os)"
ARCH="$(detect_arch)"
INIT="$(detect_init)"

require_root_and_tools() {
  if [ "$(id -u)" != "0" ]; then
    die "must run as root (use sudo). detected uid=$(id -u)"
  fi
  for tool in curl tar; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
  done
}

sha_verify() {
  # Reads "<sha256>  <filename>" lines on stdin, exits non-zero on mismatch.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c -
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c -
  else
    die "neither sha256sum nor shasum found — cannot verify download"
  fi
}

# -----------------------------------------------------------------------
# Service unit / plist templates (heredoc — self-contained)
# -----------------------------------------------------------------------

systemd_unit() {
  cat <<EOF
# emisar systemd unit. Deliberately minimal — emisar is a sysadmin's
# deputy, not a kernel sandbox. The trust model is:
#
#   * The runner process itself runs as an unprivileged user.
#   * Actions can do whatever the OS lets that user do.
#   * Operators who want specific actions to need root configure
#     sudo or polkit rules for the runner user.
#   * Operators who want defense-in-depth (ProtectSystem, ProtectHome,
#     RestrictNamespaces, MemoryDenyWriteExecute, etc.) drop in an
#     /etc/systemd/system/emisar.service.d/harden.conf override.
#     See docs/install.md → "Hardening (optional)" for a template.
#
# Aggressive sandboxing is NOT applied by default because every
# directive that protects the runner also propagates to its children:
# blocking /home reads, JIT interpreters, sysctl writes, dmesg,
# namespace operations, and so on. That fights the operator instead
# of helping them.

[Unit]
Description=emisar local enforcement runner
Documentation=https://github.com/${REPO}
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
EnvironmentFile=-${ETC_DIR}/runner.env
ExecStart=${BIN_DIR}/emisar --config ${ETC_DIR}/config.yaml connect
ExecReload=/bin/kill -HUP \$MAINPID

# Restart only on failure — clean shutdowns stay shut down.
# StartLimitBurst caps a permanently-broken config (e.g., revoked
# auth key returning 401) so it doesn't hammer the cloud forever.
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=300
StartLimitBurst=5

# Cancel grace: longer than the longest action's cancel_grace so
# systemd doesn't SIGKILL us mid-cleanup. 7 minutes covers the
# bundled cassandra.nodetool_repair (5m).
TimeoutStopSec=7m
KillMode=mixed
KillSignal=SIGTERM
SendSIGKILL=yes

# Cheap, doesn't block any legitimate action: prevent runner and
# children from creating new SUID/SGID binaries.
RestrictSUIDSGID=yes

# Logging via journald.
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

launchd_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.emisar.runner</string>

    <key>ProgramArguments</key>
    <array>
        <string>${BIN_DIR}/emisar</string>
        <string>--config</string>
        <string>${ETC_DIR}/config.yaml</string>
        <string>connect</string>
    </array>

    <!-- Supervision: relaunch on exit, with throttling. KeepAlive
         restarts even on clean exits (matching systemd Restart=always
         semantics); use SuccessfulExit=false to skip restart on code 0
         only. We prefer Restart=on-failure semantics so the operator
         can launchctl stop without an immediate relaunch. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key><false/>
        <key>Crashed</key><true/>
    </dict>
    <key>ThrottleInterval</key><integer>5</integer>

    <!-- Read runner.env for EMISAR_AUTH_KEY. launchd doesn't have
         EnvironmentFile so we splice the var below; the install script
         injects placeholders during install. -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin</string>
    </dict>

    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>${LOG_DIR}/emisar.out.log</string>
    <key>StandardErrorPath</key><string>${LOG_DIR}/emisar.err.log</string>
    <key>WorkingDirectory</key><string>${DATA_DIR}</string>

    <!-- Cancel grace — give the runner up to 7 minutes for graceful
         shutdown before launchd hard-kills. -->
    <key>ExitTimeOut</key><integer>420</integer>
</dict>
</plist>
EOF
}

config_skeleton() {
  cat <<EOF
schema_version: 1

runner:
  # group is the cloud UI's auto-grouping key. Pick a stable label
  # that names this fleet (e.g., role + region).
  group: REPLACE_ME
  labels:
    # Free-form tags. The cloud UI uses these for filtering / search.
    role: REPLACE_ME
    environment: prod

cloud:
  # WSS URL of the control plane. Until you set this, the runner runs in
  # local-only mode (CLI subcommands work; \`connect\` exits with an
  # error).
  url: ""
  # Name of the environment variable holding the runner auth key. The
  # systemd unit reads ${ETC_DIR}/runner.env which should contain:
  #   EMISAR_AUTH_KEY=emkey-auth-...
  auth_key_env: EMISAR_AUTH_KEY
  token_path: ${DATA_DIR}/token
  heartbeat_every: 30s
  reconnect_min: 1s
  reconnect_max: 60s

paths:
  data_dir: ${DATA_DIR}
  work_dir: ${DATA_DIR}/work
  packs:
    - /etc/emisar/packs

execution:
  # SIGTERM->SIGKILL window when cancelling an action. Per-action
  # override via execution.cancel_grace on the action YAML.
  cancel_grace: 30s

events:
  jsonl_path: ${LOG_DIR}/events.jsonl
  max_preview_bytes: 4096
  max_size_bytes: 104857600     # 100 MiB
  max_backups: 5

redaction:
  rules: []
EOF
}

runner_env_skeleton() {
  cat <<'EOF'
# Drop your cloud auth key here. The systemd unit's EnvironmentFile=
# directive loads this file at start (failure to read is non-fatal,
# but the runner will refuse to connect without the key).
#
# Format is shell-style KEY=VALUE, one per line, no quotes.
#
#EMISAR_AUTH_KEY=emkey-auth-replace-me
EOF
}

# -----------------------------------------------------------------------
# Version resolution + download
# -----------------------------------------------------------------------

resolve_latest_version() {
  # The runner ships under the `runner-v*` tag prefix; the MCP bridge
  # uses `mcp-v*` and shouldn't be picked up here. We use the GitHub
  # releases API (anonymous, 60 req/hr per IP — fine for install
  # scripts) and grep the first matching tag. The /releases/latest
  # redirect would only work if we made the runner the "latest" via
  # `make_latest: legacy`, which we do, BUT the bridge release stream
  # might still claim it temporarily — filtering by prefix is more
  # robust than trusting the Latest pointer.
  local out
  out=$(curl -fsSL -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${REPO}/releases?per_page=30") \
    || die "could not query GitHub releases API"
  printf '%s\n' "$out" \
    | grep -oE '"tag_name":[[:space:]]*"runner-v[^"]+"' \
    | head -1 \
    | sed -E 's/.*"(runner-v[^"]+)".*/\1/'
}

download_release() {
  local version="$1" tmp="$2"
  # `version` is the full tag (e.g. `runner-v0.3.0`). The tarball
  # inside the release uses just the semver portion — strip the
  # `runner-v` prefix.
  local version_num="${version#runner-v}"
  local base="https://github.com/${REPO}/releases/download/${version}"
  local name="emisar-${version_num}-${OS}-${ARCH}"
  local tarball="${name}.tar.gz"

  log "downloading ${tarball}"
  curl -sSL --fail -o "${tmp}/${tarball}" "${base}/${tarball}" \
    || die "failed to download ${base}/${tarball}"

  log "downloading SHA256SUMS"
  curl -sSL --fail -o "${tmp}/SHA256SUMS" "${base}/SHA256SUMS" \
    || die "failed to download ${base}/SHA256SUMS"

  log "verifying checksum"
  (
    cd "${tmp}"
    grep -E "  ${tarball}\$" SHA256SUMS | sha_verify
  ) || die "checksum verification failed for ${tarball}"

  log "extracting"
  tar -C "${tmp}" -xzf "${tmp}/${tarball}"
  printf '%s\n' "${tmp}/${name}"
}

# -----------------------------------------------------------------------
# User + directory + service setup
# -----------------------------------------------------------------------

ensure_user_linux() {
  if id "${SERVICE_USER}" >/dev/null 2>&1; then
    return 0
  fi
  log "creating system user ${SERVICE_USER}"
  if command -v useradd >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin \
      --home-dir "${DATA_DIR}" "${SERVICE_USER}"
  elif command -v adduser >/dev/null 2>&1; then
    # BusyBox/Alpine fallback.
    adduser -S -D -H -h "${DATA_DIR}" -s /sbin/nologin "${SERVICE_USER}"
  else
    die "neither useradd nor adduser available; cannot create service user"
  fi
}

ensure_user_macos() {
  # macOS dedicated daemon users are non-trivial to create. For dev
  # installs we run as `root`. Production macOS deployments are out of
  # scope; document and skip.
  warn "macOS install runs the runner as root by default."
  warn "for dedicated-user setups, create a _emisar user manually and edit"
  warn "the LaunchDaemon plist before reloading."
}

ensure_dirs() {
  local owner="${SERVICE_USER}:${SERVICE_GROUP}"
  if [ "${OS}" = "darwin" ]; then
    owner="root:wheel"
  fi
  for d in "${ETC_DIR}" "${DATA_DIR}" "${LOG_DIR}" "${DATA_DIR}/work"; do
    if [ ! -d "$d" ]; then
      log "mkdir $d"
      mkdir -p "$d"
    fi
    chown -R "${owner}" "$d"
  done
  chmod 750 "${ETC_DIR}" "${DATA_DIR}"
  chmod 755 "${LOG_DIR}"
}

drop_config_skeleton() {
  local cfg="${ETC_DIR}/config.yaml"
  if [ ! -f "${cfg}" ]; then
    log "writing default config to ${cfg} (edit before starting)"
    config_skeleton > "${cfg}"
    chmod 640 "${cfg}"
    chown "root:${SERVICE_GROUP}" "${cfg}" 2>/dev/null || true
    NEEDS_CONFIGURATION=1
  else
    log "config exists at ${cfg}; leaving untouched"
    NEEDS_CONFIGURATION=0
  fi

  local env="${ETC_DIR}/runner.env"
  if [ ! -f "${env}" ]; then
    log "writing runner.env stub to ${env}"
    runner_env_skeleton > "${env}"
    # Restrictive perms: only the service user can read the secret.
    chmod 600 "${env}"
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${env}" 2>/dev/null || \
      chown root:root "${env}"
  fi
}

install_binary() {
  local src="$1/emisar"
  if [ ! -f "${src}" ]; then
    die "expected binary at ${src} but it is missing"
  fi
  log "installing binary to ${BIN_DIR}/emisar"
  install -m 0755 "${src}" "${BIN_DIR}/emisar"
  # Exec the newly-installed binary to confirm it runs and matches the
  # version we asked for. Lets operators catch arch mismatches or
  # truncated downloads immediately.
  if ver_output=$("${BIN_DIR}/emisar" version 2>/dev/null); then
    log "installed: $(echo "${ver_output}" | head -1)"
  else
    warn "installed binary did not respond to 'version' subcommand"
  fi
}

install_packs_if_present() {
  local src_dir="$1/examples/packs"
  if [ ! -d "${src_dir}" ]; then
    return 0
  fi
  local dst_dir="${ETC_DIR}/packs"
  if [ -d "${dst_dir}" ]; then
    log "${dst_dir} exists; leaving installed packs untouched"
    return 0
  fi
  log "copying example packs to ${dst_dir}"
  mkdir -p "${dst_dir}"
  cp -R "${src_dir}/." "${dst_dir}/"
  if [ "${OS}" = "linux" ]; then
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${dst_dir}"
  fi
}

install_systemd() {
  local unit="/etc/systemd/system/emisar.service"
  log "writing ${unit}"
  systemd_unit > "${unit}"
  chmod 644 "${unit}"
  systemctl daemon-reload
  systemctl enable emisar.service >/dev/null
}

install_launchd() {
  local plist="/Library/LaunchDaemons/com.emisar.runner.plist"
  log "writing ${plist}"
  launchd_plist > "${plist}"
  chown root:wheel "${plist}"
  chmod 644 "${plist}"
}

start_service() {
  if [ "${NEEDS_CONFIGURATION:-0}" = "1" ]; then
    warn "skipping service start — edit ${ETC_DIR}/config.yaml and ${ETC_DIR}/runner.env first"
    return 0
  fi
  if [ "${NO_START}" = "1" ]; then
    log "--no-start: not starting service"
    return 0
  fi
  case "${INIT}" in
    systemd)
      if systemctl is-active --quiet emisar.service; then
        log "restarting emisar.service (upgrade)"
        systemctl restart emisar.service
      else
        log "starting emisar.service"
        systemctl start emisar.service
      fi
      systemctl --no-pager --full status emisar.service || true
      ;;
    launchd)
      local plist="/Library/LaunchDaemons/com.emisar.runner.plist"
      # bootout is the idempotent way to (re)load; ignore missing-target.
      launchctl bootout system "${plist}" 2>/dev/null || true
      log "loading com.emisar.runner"
      launchctl bootstrap system "${plist}"
      launchctl print system/com.emisar.runner || true
      ;;
  esac
}

stop_service_if_running() {
  case "${INIT}" in
    systemd)
      if systemctl is-active --quiet emisar.service; then
        log "stopping emisar.service for upgrade"
        systemctl stop emisar.service
      fi
      ;;
    launchd)
      local plist="/Library/LaunchDaemons/com.emisar.runner.plist"
      if [ -f "${plist}" ]; then
        log "unloading com.emisar.runner for upgrade"
        launchctl bootout system "${plist}" 2>/dev/null || true
      fi
      ;;
  esac
}

# -----------------------------------------------------------------------
# Install + uninstall flows
# -----------------------------------------------------------------------

do_install() {
  require_root_and_tools
  log "install target: ${OS}/${ARCH} via ${INIT}"
  if [ -z "${VERSION}" ]; then
    VERSION="$(resolve_latest_version)" || die "could not resolve latest version"
    log "latest release: ${VERSION}"
  else
    log "pinned release: ${VERSION}"
  fi

  if ! confirm "install emisar ${VERSION} to ${BIN_DIR}/emisar (and configure as a service)?"; then
    die "aborted by user"
  fi

  local tmp
  tmp="$(mktemp -d -t emisar-install.XXXXXX)"
  trap 'rm -rf "${tmp}"' EXIT

  local extracted
  extracted="$(download_release "${VERSION}" "${tmp}")"

  stop_service_if_running

  case "${OS}" in
    linux)  ensure_user_linux;;
    darwin) ensure_user_macos;;
  esac

  ensure_dirs
  install_binary "${extracted}"
  install_packs_if_present "${extracted}"
  drop_config_skeleton

  case "${INIT}" in
    systemd) install_systemd;;
    launchd) install_launchd;;
  esac

  start_service

  log "installed emisar ${VERSION}"
  print_next_steps
}

print_next_steps() {
  cat <<EOF

==============================================================
emisar ${VERSION} installed.

Binary:   ${BIN_DIR}/emisar
Config:   ${ETC_DIR}/config.yaml
Secrets:  ${ETC_DIR}/runner.env   (chmod 600)
Data:     ${DATA_DIR}
Logs:     ${LOG_DIR}/events.jsonl (security log)

Next steps:
  1. Edit ${ETC_DIR}/config.yaml — set runner.group, cloud.url, etc.
  2. Edit ${ETC_DIR}/runner.env — set EMISAR_AUTH_KEY=tskey-...
EOF

  case "${INIT}" in
    systemd)
      cat <<EOF
  3. Start the service:
       sudo systemctl start emisar
     Or restart after editing config:
       sudo systemctl restart emisar
  4. Check status / logs:
       sudo systemctl status emisar
       sudo journalctl -u emisar -f
EOF
      ;;
    launchd)
      cat <<EOF
  3. Load the LaunchDaemon:
       sudo launchctl bootstrap system /Library/LaunchDaemons/com.emisar.runner.plist
  4. Check logs:
       tail -f ${LOG_DIR}/emisar.err.log ${LOG_DIR}/emisar.out.log
EOF
      ;;
  esac
  echo
  echo "Uninstall:  sudo $0 --uninstall"
  echo "==============================================================="
}

do_uninstall() {
  require_root_and_tools
  log "uninstall target: ${OS}/${ARCH} via ${INIT}"
  if ! confirm "remove emisar binary, service unit, and (with --purge) data?"; then
    die "aborted"
  fi

  case "${INIT}" in
    systemd)
      if [ -f /etc/systemd/system/emisar.service ]; then
        systemctl disable --now emisar.service 2>/dev/null || true
        rm -f /etc/systemd/system/emisar.service
        systemctl daemon-reload
        log "removed systemd unit"
      fi
      ;;
    launchd)
      if [ -f /Library/LaunchDaemons/com.emisar.runner.plist ]; then
        launchctl bootout system /Library/LaunchDaemons/com.emisar.runner.plist 2>/dev/null || true
        rm -f /Library/LaunchDaemons/com.emisar.runner.plist
        log "removed launchd plist"
      fi
      ;;
  esac

  if [ -f "${BIN_DIR}/emisar" ]; then
    log "removing ${BIN_DIR}/emisar"
    rm -f "${BIN_DIR}/emisar"
  fi

  if [ "${PURGE}" = "1" ]; then
    for d in "${ETC_DIR}" "${DATA_DIR}" "${LOG_DIR}"; do
      if [ -d "$d" ]; then
        log "removing $d"
        rm -rf "$d"
      fi
    done
    if [ "${OS}" = "linux" ] && id "${SERVICE_USER}" >/dev/null 2>&1; then
      log "removing user ${SERVICE_USER}"
      if command -v userdel >/dev/null 2>&1; then
        userdel "${SERVICE_USER}" || true
      elif command -v deluser >/dev/null 2>&1; then
        deluser "${SERVICE_USER}" || true
      fi
    fi
  else
    cat <<EOF

Kept (use --purge to remove):
  ${ETC_DIR}  (config + secrets)
  ${DATA_DIR} (state + outbox + cursor)
  ${LOG_DIR}  (security log)
EOF
  fi

  log "uninstalled"
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------

case "${MODE}" in
  install)   do_install;;
  uninstall) do_uninstall;;
  *) die "internal: unknown mode ${MODE}";;
esac

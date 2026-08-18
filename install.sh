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
#   curl -fsSL https://raw.githubusercontent.com/andrewdryga/emisar/main/install.sh | sudo bash
#
#   # Pin a specific runner version (tag, with or without prefix):
#   curl -fsSL https://.../install.sh | sudo bash -s -- --version runner-v0.3.0
#   curl -fsSL https://.../install.sh | sudo bash -s -- --version 0.3.0
#
#   # Unattended (no prompts) with a fixed pack set — for CI / cloud-init:
#   curl -fsSL https://.../install.sh | sudo bash -s -- --yes --packs linux-core,postgres,redis
#
#   # Uninstall:
#   sudo bash install.sh --uninstall
#
# Idempotent: re-running upgrades in place. Safe to interrupt — every
# step has explicit success criteria; nothing partially applied is left
# in a "running but broken" state.

set -Eeuo pipefail

# -----------------------------------------------------------------------
# Configuration (env or flags)
# -----------------------------------------------------------------------

REPO="${EMISAR_REPO:-andrewdryga/emisar}"
# The workflow identity Sigstore build provenance is checked against. It is
# matched literally against the signing certificate's SubjectAlternativeName,
# which carries GitHub's canonical owner casing (AndrewDryga) — NOT the
# lowercase spelling REPO uses. Deriving this from REPO reads as obviously
# correct and fails every verification, so it is written out.
#
# A fork or mirror gets no default: we cannot vouch for a workflow we do not
# know, and pinning ours would fail their install outright. They set this
# themselves, or the check is skipped and the checksum stands alone.
ATTESTATION_WORKFLOW="${EMISAR_ATTESTATION_WORKFLOW:-}"
if [ -z "${ATTESTATION_WORKFLOW}" ] && [ "${REPO}" = "andrewdryga/emisar" ]; then
  ATTESTATION_WORKFLOW="AndrewDryga/emisar/.github/workflows/runner-release.yml"
fi
VERSION="${VERSION:-}"            # empty = latest stable
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
ETC_DIR="${ETC_DIR:-/etc/emisar}"
DATA_DIR="${DATA_DIR:-/var/lib/emisar}"
LOG_DIR="${LOG_DIR:-/var/log/emisar}"
SERVICE_USER="${SERVICE_USER:-emisar}"
SERVICE_GROUP="${SERVICE_GROUP:-emisar}"
ASSUME_YES="${ASSUME_YES:-0}"
# Pack selection. EMISAR_PACKS being *present in the environment* — even
# empty — means the operator is managing packs explicitly: install exactly
# the listed set (possibly none) and skip host detection / suggestions. So
# we test set-ness (${VAR+set}), not non-emptiness: a templated
# `EMISAR_PACKS='${emisar_packs}'` that renders empty is still an explicit
# "no extra packs", not an invitation to suggest. --packs sets it too.
PRE_PACKS="${EMISAR_PACKS:-}"     # the explicit list itself (may be empty)
PACKS_EXPLICIT=0; [ -n "${EMISAR_PACKS+set}" ] && PACKS_EXPLICIT=1
NO_START="${NO_START:-0}"
NO_SERVICE="${NO_SERVICE:-0}"     # skip user + service unit + activation
PREVERIFIED_BUNDLE=""              # internal: verified `emisar update` handoff
SERVICE_STARTED=0
MODE="install"                    # install|uninstall
ENROLLMENT_KEY_UPDATE=0           # existing runner.env needs the supplied key

usage() {
  cat <<'USAGE'
emisar installer

Usage: install.sh [--version TAG] [--uninstall] [--no-start] [--yes] [--packs LIST]

Flags:
  --version TAG      Install a specific runner release tag. Default: latest.
                     Accepts `runner-vX.Y.Z`, `vX.Y.Z`, or bare `X.Y.Z`
                     (bare/v-prefixed forms are auto-prefixed with `runner-v`).
  --uninstall        Stop the service; remove the binary, service unit,
                     and cached runner token.
                     Keeps config, local evidence, and logs by default.
  --purge            With --uninstall, also delete config + data + logs.
  --no-start         Install + enable the service but don't start it.
  --no-service       Binary-only install: skip system user creation,
                     systemd/launchd unit, and service activation.
                     Use on hosts without a real init (containers,
                     cloud shell, CI runners) or for one-shot smoke
                     runs. Operator runs the binary by hand afterward.
  --bin-dir DIR      Install path for the binary (default /usr/local/bin)
  --etc-dir DIR      Config dir (default /etc/emisar)
  --data-dir DIR     Data dir (default /var/lib/emisar)
  --log-dir DIR      Log dir (default /var/log/emisar)
  --user NAME        Service user (default emisar)
  --yes              Skip confirmation prompts. Requires an explicit
                     --packs LIST or EMISAR_PACKS (empty means no new packs).
  --packs LIST       Comma/space-separated packs to install up front, e.g.
                     --packs redis,postgres. Installs exactly these — no
                     host detection, no prompt — from the bundle if present,
                     else the registry. For unattended provisioning.
  --help             This message.

Env vars accepted: VERSION, BIN_DIR, ETC_DIR, DATA_DIR, LOG_DIR,
SERVICE_USER, SERVICE_GROUP, ASSUME_YES, EMISAR_PACKS, NO_START,
NO_SERVICE, EMISAR_REPO, EMISAR_GITHUB_TOKEN, EMISAR_URL,
EMISAR_ENROLLMENT_KEY, RUNNER_GROUP, RUNNER_LABEL_<KEY>.

EMISAR_URL + EMISAR_ENROLLMENT_KEY are baked into config.yaml + runner.env
at install time so the runner boots without a follow-up edit.
RUNNER_GROUP defaults to `hostname -s`. Each RUNNER_LABEL_<KEY>=<value>
(e.g. RUNNER_LABEL_ROLE=web) is baked in as a runner label the console
filters on; set as many as you like.

Setting EMISAR_PACKS (the env form of --packs), even to an empty string,
makes the pack list explicit: the installer installs exactly those packs
and never host-detects or prompts to add suggested ones. Leave it unset for
an interactive install with host-matched recommendations. Unattended installs
must set it explicitly, including to an empty string.
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

# A flag whose value is missing must say so, not die on `set -u` with a raw
# "$2: unbound variable" and a line number. Ported from install-mcp.sh, which
# has had this since it shipped; these flags freeze at 1.0.
require_value() {
  local flag="$1"
  if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == -* ]]; then
    printf 'flag %s requires a value\n' "$flag" >&2
    usage >&2
    exit 2
  fi
}

# --data-dir/--log-dir feed `chown -R`, and under --purge they feed `rm -rf`.
# Neither was validated, so `--data-dir /var/lib` recursively chowned the host's
# whole /var/lib to the service user, and `--data-dir / --purge` was `rm -rf /`.
# Require an absolute path at least two components deep and refuse the obvious
# system roots — the installer owns directories it creates, not shared ones.
# `die` is defined further down, after argument parsing, so this reports the
# same way require_value does.
reject_dir() {
  printf '%s\n' "$1" >&2
  exit 2
}

require_owned_dir() {
  local flag="$1" path="$2"
  case "$path" in
    /*) ;;
    *) reject_dir "${flag} must be an absolute path (got ${path})" ;;
  esac
  case "${path%/}" in
    "" | /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /opt | /proc | /root | /run | \
      /sbin | /srv | /sys | /tmp | /usr | /var | /var/lib | /var/log | /var/run | /Applications | \
      /Library | /System | /Users | /private)
      reject_dir "${flag} must not be a system directory (got ${path})"
      ;;
  esac
  case "${path#/}" in
    */*) ;;
    *) reject_dir "${flag} must be at least two path components deep (got ${path})" ;;
  esac
}

PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) require_value "$@"; VERSION="$(normalize_version "$2")"; shift 2;;
    --uninstall) MODE="uninstall"; shift;;
    --purge) PURGE=1; shift;;
    --no-start) NO_START=1; shift;;
    --no-service) NO_SERVICE=1; shift;;
    --bin-dir) require_value "$@"; BIN_DIR="$2"; shift 2;;
    --etc-dir) require_value "$@"; ETC_DIR="$2"; shift 2;;
    --data-dir) require_value "$@"; DATA_DIR="$2"; shift 2;;
    --log-dir) require_value "$@"; LOG_DIR="$2"; shift 2;;
    --user) require_value "$@"; SERVICE_USER="$2"; SERVICE_GROUP="$2"; shift 2;;
    --yes|-y) ASSUME_YES=1; shift;;
    --packs) require_value "$@"; PRE_PACKS="$2"; PACKS_EXPLICIT=1; shift 2;;
    --preverified-bundle) require_value "$@"; PREVERIFIED_BUNDLE="$2"; shift 2;;
    --help|-h) usage; exit 0;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2;;
  esac
done

# Validate the directory inputs HERE, not in the flag arms. require_owned_dir was
# reachable only through --etc-dir/--data-dir/--log-dir, while the usage text
# advertises ETC_DIR, DATA_DIR, LOG_DIR and BIN_DIR as supported environment
# variables — and that path validated nothing. A template rendering /etc/${x} or
# /var/lib/${x} with an empty x therefore reached `rm -rf` under --uninstall
# --purge, and `chown -R` on a host's real /var/lib. The flag guard exists
# because --data-dir /var/lib already did the second one to a host. BIN_DIR was
# unguarded in both forms and reaches a root chmod 755.
require_owned_dir BIN_DIR "${BIN_DIR}"
require_owned_dir ETC_DIR "${ETC_DIR}"
require_owned_dir DATA_DIR "${DATA_DIR}"
require_owned_dir LOG_DIR "${LOG_DIR}"
if [ -n "${PREVERIFIED_BUNDLE}" ]; then
  case "${PREVERIFIED_BUNDLE}" in
    /*) ;;
    *) reject_dir "--preverified-bundle must be an absolute path" ;;
  esac
  [ -d "${PREVERIFIED_BUNDLE}" ] || \
    reject_dir "--preverified-bundle is not a directory: ${PREVERIFIED_BUNDLE}"
  [ -n "${VERSION}" ] || \
    reject_dir "--preverified-bundle requires --version"
fi

# -----------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------

log()   { printf '\033[1;34m[install]\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[install]\033[0m %s\n' "$*" >&2; exit 1; }

# Every value baked into config.yaml goes through here first.
#
# These land inside YAML scalars. A value carrying a quote does not corrupt the
# file — it ADDS to it, and a newline injects whole config KEYS: `cloud.url`,
# `paths.packs`, `admission`. Cloud-init rendering an instance tag straight into
# RUNNER_LABEL_* is the realistic source, so this is not a hypothetical hostile
# operator. Failing here also beats the alternative, which was a runner that
# installs cleanly and then refuses to parse its own config on first boot.
safe_config_value() {
  case "$1" in
    "") return 1 ;;
    *[!A-Za-z0-9._:/@+-]*) return 1 ;;
  esac
  return 0
}
die_systemd_required() {
  local reason="$1"
  die "this installer requires systemd on Linux (${reason}).

For containers, cloud shells, CI runners, or hosts where you supervise the runner yourself, use --no-service:
  curl -fsSL https://emisar.dev/install.sh | sudo EMISAR_ENROLLMENT_KEY=emkey-enroll-... EMISAR_URL=https://emisar.dev bash -s -- --no-service

If you are reusing a portal-generated one-liner, keep its EMISAR_ENROLLMENT_KEY/EMISAR_URL values and replace the final 'bash' with:
  bash -s -- --no-service"
}
# log()/warn()/die() ALL write to stderr. Function return values come
# back via stdout (e.g. `download_release` printf's the extracted dir).
# A stdout-bound log() would leak into command substitutions and corrupt
# the captured value — caused a "binary missing" misreport in 0.1.0.
confirm() {
  if [ "$ASSUME_YES" = "1" ]; then return 0; fi

  # `curl | bash` makes stdin the script content, not a terminal — so a
  # plain `read` consumes the NEXT LINE of the script and reports an
  # "empty" answer to every prompt. Try /dev/tty so the operator can
  # actually answer. No controlling terminal means there is nobody who can
  # consent, so the safe answer is no; unattended callers must pass --yes.
  if [ -t 0 ]; then
    printf '%s [y/N] ' "$1"
    read -r reply || reply=""
  elif { exec 3</dev/tty; } 2>/dev/null; then
    printf '%s [y/N] ' "$1" >/dev/tty
    read -r reply <&3 || reply=""
    exec 3<&-
  else
    return 1
  fi
  case "$reply" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac
}

tty_available() {
  if [ -t 0 ]; then
    return 0
  fi
  if { exec 3</dev/tty; } 2>/dev/null; then
    exec 3<&-
    return 0
  fi
  return 1
}

require_explicit_unattended_packs() {
  if [ "$ASSUME_YES" = "1" ]; then
    [ "$PACKS_EXPLICIT" = "1" ] || \
      die "--yes requires an explicit pack set. Pass --packs <ids> or set EMISAR_PACKS (an empty value installs no new packs)."
    return 0
  fi

  tty_available || \
    die "non-interactive install requires --yes and an explicit --packs <ids> or EMISAR_PACKS value (empty installs no new packs)."
}

validate_enrollment_key_input() {
  [ -n "${EMISAR_ENROLLMENT_KEY:-}" ] || return 0
  [[ "${EMISAR_ENROLLMENT_KEY}" =~ ^emkey-enroll-[A-Za-z0-9_-]{20,}$ ]] || \
    die "EMISAR_ENROLLMENT_KEY is not a valid emkey-enroll- credential"
}

# Resolve an enrollment-key update before the installer stops the service.
# The runner's token fingerprint makes a changed key re-register the same
# configured id or hostname and replace the cached token on its next connect.
prepare_enrollment_key_update() {
  validate_enrollment_key_input

  [ -n "${EMISAR_ENROLLMENT_KEY:-}" ] || return 0

  local env="${ETC_DIR}/runner.env" current="" line
  if [ -f "${env}" ]; then
    while IFS= read -r line || [ -n "${line}" ]; do
      case "${line}" in
        EMISAR_ENROLLMENT_KEY=*) current="${line#EMISAR_ENROLLMENT_KEY=}";;
      esac
    done < "${env}"
  else
    # Fresh installs write the supplied key when the environment file is created.
    return 0
  fi

  [ "${current}" = "${EMISAR_ENROLLMENT_KEY}" ] || ENROLLMENT_KEY_UPDATE=1
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
      # Three conditions to call this a systemd host:
      #   1. systemctl binary present
      #   2. /run/systemd/system exists — systemd's documented marker
      #      that "systemd is running on this system" (per systemd(1));
      #      survives the cloud-shell / container case where systemctl
      #      is installed but PID 1 is not systemd.
      #   3. (Optional sanity) systemctl --quiet is-system-running
      #      doesn't reject. We don't enforce it because some early-boot
      #      states return "starting" or "degraded" and we still want
      #      the install to proceed.
      if ! command -v systemctl >/dev/null 2>&1; then
        die_systemd_required "systemctl not found on \$PATH"
      fi
      if [ ! -d /run/systemd/system ]; then
        die_systemd_required "systemctl present but /run/systemd/system missing - PID 1 is not systemd; this looks like a container or cloud shell"
      fi
      echo systemd
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

OS=""
ARCH=""
INIT=""

detect_target() {
  OS="$(detect_os)"
  ARCH="$(detect_arch)"
  # With --no-service, skip init detection entirely — the whole point of
  # the flag is to install on hosts that don't HAVE a real init (cloud
  # shell, containers, CI). detect_init() would die on those before we
  # ever reach do_install.
  #
  # Uninstall degrades an undetectable init to "none" instead of dying: there
  # is nothing to install, and do_uninstall's service teardown is a case that
  # no-ops on "none". Dying here meant a container install (the documented
  # --no-service path) could not be removed with the very command this script
  # prints on success — it failed with an error about INSTALLING. Detection
  # still RUNS, so a real systemd or launchd host removes its unit as before.
  if [ "${NO_SERVICE}" = "1" ]; then
    INIT="none"
  elif [ "${MODE}" = "uninstall" ]; then
    INIT="$(detect_init 2>/dev/null)" || INIT="none"
  else
    INIT="$(detect_init)"
  fi
}

require_root_and_tools() {
  if [ "$(id -u)" != "0" ]; then
    die "must run as root (use sudo). detected uid=$(id -u)"
  fi
  local tools=(tar)
  [ -n "${PREVERIFIED_BUNDLE}" ] || tools+=(curl)
  for tool in "${tools[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
  done
}

sha_verify() {
  # Reads "<sha256>  <filename>" lines on stdin, exits non-zero on
  # mismatch. Output is silenced (>/dev/null) so the caller can print
  # its own clean status line instead of the tool's "<file>: OK".
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c - >/dev/null
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c - >/dev/null
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
#     See runner/README.md → "Hardening (optional)" for a template.
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

# The rate limiter lives in [Unit]. systemd moved these keys out of [Service]
# in v230 and only keeps the legacy un-suffixed spellings there as compat
# aliases, so StartLimitIntervalSec under [Service] is parsed as an unknown key
# and silently dropped — leaving the default 10s window, which RestartSec=5s can
# never fill. The cap below is what stops a permanently-broken config (e.g. a
# revoked enrollment key returning 401) hammering the cloud forever.
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
EnvironmentFile=-${ETC_DIR}/runner.env
ExecStart=${BIN_DIR}/emisar --config ${ETC_DIR}/config.yaml connect
ExecReload=/bin/kill -HUP \$MAINPID

# Restart only on failure — clean shutdowns stay shut down. The burst cap that
# bounds a permanently-broken config lives in [Unit] above.
Restart=on-failure
RestartSec=5s

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
        <string>${ETC_DIR}/run-launchd.sh</string>
        <string>${BIN_DIR}/emisar</string>
        <string>${ETC_DIR}/config.yaml</string>
        <string>${ETC_DIR}/runner.env</string>
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

    <!-- run-launchd.sh loads the root-owned runner.env before exec.
         launchd has no EnvironmentFile equivalent. -->
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

launchd_runner_script() {
  cat <<'LAUNCHD_RUNNER'
#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: run-launchd.sh <emisar-binary> <config> <runner-env>" >&2
  exit 2
fi

binary="$1"
config="$2"
runner_env="$3"

if [ -f "$runner_env" ]; then
  set -a
  . "$runner_env"
  set +a
fi

exec "$binary" --config "$config" connect
LAUNCHD_RUNNER
}

config_skeleton() {
  # Pre-fill cloud.url from EMISAR_URL when the install command set it.
  # We translate http(s):// → ws(s):// so the YAML carries the websocket
  # URL the runner actually dials. Empty otherwise so the operator edits
  # before connecting.
  local cloud_url=""
  if [ -n "${EMISAR_URL:-}" ]; then
    case "${EMISAR_URL}" in
      https://*) cloud_url="wss://${EMISAR_URL#https://}";;
      http://*)  cloud_url="ws://${EMISAR_URL#http://}";;
      *)         cloud_url="${EMISAR_URL}";;  # already wss:// or bare host
    esac
  fi
  # Group defaults to the short hostname so a fresh install boots
  # without an edit. Operators relabel a runner later from the portal
  # or by editing config.yaml. The runner schema requires a non-empty
  # group (see runner/internal/config/config.go), so falling back to
  # the bare `hostname` then a literal "emisar-runner" covers minimal
  # images where neither `hostname -s` nor `/etc/hostname` is populated.
  local default_group
  default_group="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo emisar-runner)"
  local group="${RUNNER_GROUP:-${default_group}}"
  safe_config_value "${group}" ||
    die "runner group has characters that cannot be written to config.yaml: ${group}"
  [ -z "${cloud_url}" ] || safe_config_value "${cloud_url}" ||
    die "EMISAR_URL has characters that cannot be written to config.yaml: ${EMISAR_URL:-}"
  cat <<EOF
schema_version: 1

runner:
  # group is the console's auto-grouping key. Defaults to the host's
  # short hostname; override by editing this line or by passing
  # RUNNER_GROUP=... to install.sh next time.
  group: ${group}
  labels:
    # Free-form tags. The console uses these for filtering / search.
    # Set RUNNER_LABEL_<KEY>=<value> at install time to bake them in
    # (e.g. RUNNER_LABEL_ROLE=web), or uncomment + edit below.
EOF
  local label_var label_key wrote_label=0
  for label_var in "${!RUNNER_LABEL_@}"; do
    [ -n "${!label_var}" ] || continue
    label_key="$(printf '%s' "${label_var#RUNNER_LABEL_}" | tr '[:upper:]' '[:lower:]')"
    [ -n "$label_key" ] || continue
    safe_config_value "${label_key}" ||
      die "${label_var}: label name has characters that cannot be written to config.yaml"
    safe_config_value "${!label_var}" ||
      die "${label_var}: label value has characters that cannot be written to config.yaml"
    printf '    %s: "%s"\n' "$label_key" "${!label_var}"
    wrote_label=1
  done
  if [ "$wrote_label" = 0 ]; then
    printf '    # role: web\n'
    printf '    # environment: prod\n'
  fi
  cat <<EOF

cloud:
  # WSS URL of the control plane. Until you set this, the runner runs in
  # local-only mode (CLI subcommands work; \`connect\` exits with an
  # error).
  url: "${cloud_url}"
  # Name of the environment variable holding the runner enrollment key. The
  # systemd unit reads ${ETC_DIR}/runner.env which should contain:
  #   EMISAR_ENROLLMENT_KEY=emkey-enroll-...
  enrollment_key_env: EMISAR_ENROLLMENT_KEY
  token_path: ${DATA_DIR}/token
  heartbeat_every: 30s
  reconnect_min: 1s
  reconnect_max: 60s

paths:
  data_dir: ${DATA_DIR}
  packs:
    - ${ETC_DIR}/packs

execution:
  # SIGTERM->SIGKILL window when cancelling an action. Per-action
  # override via execution.cancel_grace on the action YAML.
  cancel_grace: 30s
  # Extra host env vars to forward into actions, on top of the always-on
  # PATH/LANG/LC_ALL/TERM. Add the ones a pack's auth needs (see the pack's
  # setup notes) and set their values in ${ETC_DIR}/runner.env. e.g.:
  #   inherit_env:
  #     - NOMAD_ADDR
  #     - NOMAD_TOKEN

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
  # If the install command set EMISAR_ENROLLMENT_KEY, bake it in so the runner
  # boots without a follow-up edit. Otherwise emit a commented-out
  # placeholder the operator fills in by hand.
  if [ -n "${EMISAR_ENROLLMENT_KEY:-}" ]; then
    cat <<EOF
# Cloud enrollment key. Loaded at runner start via systemd's EnvironmentFile=
# (failure to read is non-fatal, but the runner refuses to connect
# without the key).
EMISAR_ENROLLMENT_KEY=${EMISAR_ENROLLMENT_KEY}
EOF
  else
    cat <<'EOF'
# Drop your cloud enrollment key here. The systemd unit's EnvironmentFile=
# directive loads this file at start (failure to read is non-fatal,
# but the runner will refuse to connect without the key).
#
# Format is shell-style KEY=VALUE, one per line, no quotes.
#
#EMISAR_ENROLLMENT_KEY=emkey-enroll-replace-me
EOF
  fi

  # Shared note (literal heredoc, no interpolation): pack credentials too.
  cat <<'EOF'

# Pack auth tokens go here too — anything a pack's actions read from the
# environment (NOMAD_TOKEN, CONSUL_HTTP_TOKEN, PGPASSWORD, GRAFANA_TOKEN, ...).
# Then allowlist each NAME in config.yaml under execution.inherit_env so the
# runner forwards it into the action (it is merged with the always-on
# PATH/LANG/LC_ALL/TERM). What a given pack needs: emisar pack info <id>.
#
#NOMAD_ADDR=http://127.0.0.1:4646
#NOMAD_TOKEN=...
EOF
}

# Replace only the enrollment key in runner.env. Pack credentials and operator
# comments stay byte-for-byte in place, and the new secret never appears in a
# process argument.
write_enrollment_key() {
  local env="${ETC_DIR}/runner.env" staged line wrote=0
  staged="$(mktemp "${env}.tmp.XXXXXX")" || die "could not stage ${env}"
  chmod 600 "${staged}"

  if ! while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      EMISAR_ENROLLMENT_KEY=*)
        if [ "${wrote}" = "0" ]; then
          printf 'EMISAR_ENROLLMENT_KEY=%s\n' "${EMISAR_ENROLLMENT_KEY}"
          wrote=1
        fi
        ;;
      *) printf '%s\n' "${line}";;
    esac
  done < "${env}" > "${staged}"; then
    rm -f "${staged}"
    die "could not update ${env}"
  fi

  if [ "${wrote}" = "0" ]; then
    printf 'EMISAR_ENROLLMENT_KEY=%s\n' "${EMISAR_ENROLLMENT_KEY}" >> "${staged}" || {
      rm -f "${staged}"
      die "could not update ${env}"
    }
  fi

  chmod 600 "${staged}"
  chown "root:${SERVICE_GROUP}" "${staged}" 2>/dev/null || chown root:root "${staged}"
  mv -f "${staged}" "${env}" || {
    rm -f "${staged}"
    die "could not activate updated ${env}"
  }
  log "updated enrollment key in ${env}"
}

# Remove the cached bearer token. The runner derives its external identity from
# its configured id or the current hostname, not from installer-managed state.
remove_runner_token() {
  local path
  for path in "${DATA_DIR}/token" "${DATA_DIR}/token.json"; do
    if [ -e "${path}" ] || [ -L "${path}" ]; then
      log "removing ${path}"
      rm -f "${path}" || die "could not remove runner token at ${path}"
    fi
  done
}

ENROLLMENT_STATE_BACKED_UP=0

backup_enrollment_state() {
  [ "${ENROLLMENT_KEY_UPDATE}" = "1" ] || return 0

  local backup="${tmp}/enrollment-state" path
  mkdir -m 700 "${backup}"
  cp -pP "${ETC_DIR}/runner.env" "${backup}/runner.env" || \
    die "could not back up ${ETC_DIR}/runner.env"
  for path in "${DATA_DIR}/token" "${DATA_DIR}/token.json"; do
    if [ -f "${path}" ] || [ -L "${path}" ]; then
      cp -pP "${path}" "${backup}/$(basename "${path}")" || \
        die "could not back up runner authentication state at ${path}"
    fi
  done
  ENROLLMENT_STATE_BACKED_UP=1
}

restore_enrollment_state() {
  [ "${ENROLLMENT_STATE_BACKED_UP}" = "1" ] || return 0

  local backup="${tmp}/enrollment-state" path name
  for path in "${DATA_DIR}/token" "${DATA_DIR}/token.json"; do
    name="$(basename "${path}")"
    rm -f "${path}" 2>/dev/null || true
    if [ -e "${backup}/${name}" ] || [ -L "${backup}/${name}" ]; then
      cp -pP "${backup}/${name}" "${path}" || \
        warn "could not restore runner authentication state at ${path}"
    fi
  done
  cp -pP "${backup}/runner.env" "${ETC_DIR}/runner.env" || \
    warn "could not restore ${ETC_DIR}/runner.env"
  warn "restored the previous enrollment key and token"
}

# -----------------------------------------------------------------------
# Version resolution + download
# -----------------------------------------------------------------------

# --proto-redir is https-only: this helper may carry EMISAR_GITHUB_TOKEN, and a
# redirect that downgrades the scheme would put that bearer on the wire in the
# clear. The URL is either the hardcoded GitHub HTTPS API or a test TLS server.
github_api() {
  if [ -n "${EMISAR_GITHUB_TOKEN:-}" ]; then
    # Header via process substitution, never argv — /proc/PID/cmdline is
    # world-readable while each API call runs.
    curl --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 --retry 2 -fsSL -H 'Accept: application/vnd.github+json' \
      -H @<(printf 'Authorization: Bearer %s\n' "${EMISAR_GITHUB_TOKEN}") "$@"
  else
    # Bash 3.2 (the macOS system Bash) treats an expanded empty local array as
    # unbound under `set -u`, so keep the no-token path array-free.
    curl --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 --retry 2 -fsSL -H 'Accept: application/vnd.github+json' "$@"
  fi
}

resolve_latest_version() {
  # The runner ships under the `runner-v*` tag prefix; the MCP bridge
  # uses `mcp-v*` and shouldn't be picked up here. We use the GitHub
  # releases API and grep the first matching tag. Callers that share an
  # egress IP can provide EMISAR_GITHUB_TOKEN to avoid anonymous API
  # rate limits. The /releases/latest
  # redirect would only work if we made the runner the "latest" via
  # `make_latest: legacy`, which we do, BUT the bridge release stream
  # might still claim it temporarily — filtering by prefix is more
  # robust than trusting the Latest pointer.
  local out
  out=$(github_api \
    "https://api.github.com/repos/${REPO}/releases?per_page=100") \
    || die "could not query GitHub releases API"
  # Split the response one release per line, then drop drafts and prereleases.
  # Without that, a release marked prerelease — or a draft, once
  # EMISAR_GITHUB_TOKEN makes it visible — became what every unpinned
  # `curl | sudo bash` installed.
  #
  # Then take the HIGHEST version, not the first. The API orders by creation, so
  # a backport to an older line published after a newer minor sat at the top and
  # became "latest" for every fresh install. Sorted numerically field by field —
  # `sort -V` is not portable to every host this script runs on, and a lexical
  # sort puts v0.9.0 above v0.10.0.
  printf '%s\n' "$out" \
    | tr '{' '\n' \
    | grep -v '"draft":[[:space:]]*true' \
    | grep -v '"prerelease":[[:space:]]*true' \
    | grep -oE '"tag_name":[[:space:]]*"runner-v[0-9]+\.[0-9]+\.[0-9]+"' \
    | sed -E 's/.*"runner-v([0-9]+\.[0-9]+\.[0-9]+)".*/\1/' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1 \
    | sed -E 's/^/runner-v/'
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
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 -sSL --fail -o "${tmp}/${tarball}" "${base}/${tarball}" \
    || die "failed to download ${base}/${tarball}"

  log "downloading SHA256SUMS"
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 -sSL --fail -o "${tmp}/SHA256SUMS" "${base}/SHA256SUMS" \
    || die "failed to download ${base}/SHA256SUMS"

  # Pull the expected hash for our tarball out of SHA256SUMS so we can
  # show it in the status line. The verification itself is done by
  # sha_verify (silenced) so we print one clean line instead of the
  # tool's raw "<file>: OK".
  local expected
  expected="$(grep -E "  ${tarball}\$" "${tmp}/SHA256SUMS" | awk '{print $1}')"
  (
    cd "${tmp}"
    grep -E "  ${tarball}\$" SHA256SUMS | sha_verify
  ) || die "checksum verification failed for ${tarball}"
  log "checksum verified  sha256:${expected:0:16}…"

  verify_attestation "${tmp}/${tarball}" "${tarball}"

  log "extracting"
  # --no-same-owner/--no-same-permissions: we run as root, and the archive's
  # recorded uid/gid and mode bits are not a trust input — the install paths
  # get their ownership explicitly below.
  tar -C "${tmp}" --no-same-owner --no-same-permissions -xzf "${tmp}/${tarball}" >&2
  printf '%s\n' "${tmp}/${name}"
}

# The checksum proves the tarball matches SHA256SUMS; it says nothing about who
# produced either, since both come from the same release. The Sigstore build
# provenance does: it binds these bytes to a run of our release workflow on a
# GitHub-hosted runner. Pinning --signer-workflow is what makes that a real
# check — without it, any attestation from any workflow in the repo passes.
#
# Verification runs only when a verifier is installed. Requiring one would break
# `curl | sudo bash` on a bare host, which is the path most operators take, so a
# missing verifier warns and continues on the checksum alone. A verifier that IS
# present and says no fails the install.
verify_attestation() {
  local path="$1" name="$2"
  if [ -z "${ATTESTATION_WORKFLOW}" ]; then
    warn "no attestation workflow configured for ${REPO} — skipping provenance check for ${name}"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    warn "gh not installed — skipping release attestation check for ${name}"
    warn "verify it yourself: gh attestation verify <file> --repo ${REPO} --signer-workflow ${ATTESTATION_WORKFLOW}"
    return 0
  fi
  # gh refuses the attestation API unauthenticated — it exits 4 telling you to
  # run `gh auth login` without checking anything. Treating that as a failed
  # verification would make a GitHub login a prerequisite for installing the
  # runner, so an unauthenticated CLI skips exactly like a missing one.
  if ! gh auth status >/dev/null 2>&1; then
    warn "gh is not authenticated — skipping release attestation check for ${name}"
    warn "verify it yourself: gh attestation verify <file> --repo ${REPO} --signer-workflow ${ATTESTATION_WORKFLOW}"
    return 0
  fi
  log "verifying release attestation"
  if ! gh attestation verify "${path}" --repo "${REPO}" \
    --signer-workflow "${ATTESTATION_WORKFLOW}" >/dev/null 2>&1; then
    die "release attestation for ${name} did not verify against ${ATTESTATION_WORKFLOW} — refusing to install"
  fi
  log "attestation verified  ${ATTESTATION_WORKFLOW}"
}

require_immutable_release() {
  local version="$1" release
  release=$(github_api \
    "https://api.github.com/repos/${REPO}/releases/tags/${version}") \
    || die "could not verify release metadata for ${version}"
  grep -Eq '"immutable"[[:space:]]*:[[:space:]]*true' <<<"$release" || \
    die "release ${version} is mutable and is no longer trusted; install the latest immutable runner release"
}

# -----------------------------------------------------------------------
# User + directory + service setup
# -----------------------------------------------------------------------

ensure_user_linux() {
  if id "${SERVICE_USER}" >/dev/null 2>&1; then
    : # already exists
  elif command -v useradd >/dev/null 2>&1; then
    log "creating system user ${SERVICE_USER}"
    useradd --system --no-create-home --shell /usr/sbin/nologin \
      --home-dir "${DATA_DIR}" "${SERVICE_USER}"
  elif command -v adduser >/dev/null 2>&1; then
    # BusyBox/Alpine fallback.
    log "creating system user ${SERVICE_USER}"
    adduser -S -D -H -h "${DATA_DIR}" -s /sbin/nologin "${SERVICE_USER}"
  else
    die "neither useradd nor adduser available; cannot create service user"
  fi

  # Grant read access to the system journal and /var/log so the log
  # diagnostics work without running as root: journalctl/journalctl_grep,
  # tail_log/grep_log, failed_logins, and the dmesg actions' journalctl -k
  # fallback. Read-only group membership; best-effort and idempotent —
  # skip any group this distro doesn't define. A running service picks the
  # groups up on the post-install restart.
  for grp in systemd-journal adm; do
    grep -q "^${grp}:" /etc/group 2>/dev/null || continue
    if command -v usermod >/dev/null 2>&1; then
      usermod -aG "${grp}" "${SERVICE_USER}" 2>/dev/null || true
    elif command -v addgroup >/dev/null 2>&1; then
      addgroup "${SERVICE_USER}" "${grp}" 2>/dev/null || true
    fi
  done
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
  local etc_owner="root:${SERVICE_GROUP}"
  if [ "${OS}" = "darwin" ]; then
    owner="root:wheel"
    etc_owner="root:wheel"
  fi
  # --no-service skipped user creation, so SERVICE_USER doesn't exist
  # as an account. Fall back to root:root — the operator will be running
  # the binary by hand anyway and can chown later if needed.
  if [ "${INIT}" = "none" ] && [ "${OS}" = "linux" ]; then
    owner="root:root"
    etc_owner="root:root"
  fi
  if [ ! -d "${ETC_DIR}" ]; then
    log "mkdir ${ETC_DIR}"
    mkdir -p "${ETC_DIR}"
  fi
  # Configuration and credentials stay root-owned across upgrades. Recursively
  # handing ETC_DIR to the service account would let a compromised runner
  # rewrite its own admission, signing, and control-plane settings.
  chown "${etc_owner}" "${ETC_DIR}"
  chmod 750 "${ETC_DIR}"

  for d in "${DATA_DIR}" "${LOG_DIR}" "${DATA_DIR}/work"; do
    if [ ! -d "$d" ]; then
      log "mkdir $d"
      mkdir -p "$d"
    fi
    chown -R "${owner}" "$d"
  done
  chmod 750 "${DATA_DIR}"
  chmod 755 "${LOG_DIR}"
}

drop_config_skeleton() {
  local cfg="${ETC_DIR}/config.yaml"
  if [ ! -f "${cfg}" ]; then
    # If the install command supplied EMISAR_URL + EMISAR_ENROLLMENT_KEY, the
    # generated config + env are complete and the runner can boot. Only
    # flag NEEDS_CONFIGURATION when an operator-edit is actually needed.
    local needs=0
    if [ -z "${EMISAR_URL:-}" ] || [ -z "${EMISAR_ENROLLMENT_KEY:-}" ]; then
      needs=1
    fi
    if [ "${needs}" = "1" ]; then
      log "writing default config to ${cfg} (edit before starting)"
    else
      log "writing pre-configured config to ${cfg}"
    fi
    # Stage, then move. `config_skeleton > "${cfg}"` truncated the destination
    # BEFORE the generator ran, and the generator validates labels only after
    # emitting its first heredoc — so a label value carrying a space (cloud
    # instance tags routinely do) died mid-write. finish_install rolls back the
    # binary and the unit but not the config, so the retry saw a file that
    # existed, printed "config exists; leaving untouched", and the host stayed
    # broken forever.
    cfg_staged="$(mktemp "${cfg}.tmp.XXXXXX")"
    config_skeleton > "${cfg_staged}"
    mv -f "${cfg_staged}" "${cfg}"
    chmod 640 "${cfg}"
    chown "root:${SERVICE_GROUP}" "${cfg}" 2>/dev/null || true
    NEEDS_CONFIGURATION="${needs}"
  else
    # Config exists — preserve the operator's file. But an explicitly
    # passed RUNNER_GROUP is a deliberate provisioning instruction, so
    # honor it by rewriting only the runner.group line; nothing else is
    # touched. EMISAR_URL still applies only on a fresh install; an explicitly
    # supplied enrollment key is handled separately below.
    if [ -n "${RUNNER_GROUP:-}" ] && \
       printf '%s' "${RUNNER_GROUP}" | grep -qE '^[A-Za-z0-9._-]+$'; then
      if grep -qE '^[[:space:]]*group:[[:space:]]' "${cfg}"; then
        sed -i.bak "s|^\([[:space:]]*\)group:[[:space:]].*|\1group: ${RUNNER_GROUP}|" "${cfg}"
        rm -f "${cfg}.bak"
        log "config exists at ${cfg}; set runner.group=${RUNNER_GROUP} (rest untouched)"
      else
        warn "config at ${cfg} has no 'group:' line; set runner.group by hand"
      fi
    elif [ -n "${RUNNER_GROUP:-}" ]; then
      warn "RUNNER_GROUP='${RUNNER_GROUP}' has unexpected characters; not editing ${cfg}"
    else
      log "config exists at ${cfg}; leaving untouched"
    fi
    # An operator re-running the NEW portal's one-liner gets their enrollment
    # key rotated (below) but not their cloud.url, because this branch leaves the
    # config alone — so the runner authenticates nowhere and nothing says why.
    # Name the ignored value rather than silently dropping it.
    # Compare against the TRANSLATED value. config_skeleton rewrites https:// to
    # wss:// before storing, so grepping for the literal EMISAR_URL could never
    # match on a correctly configured host — this warning fired on every correct
    # re-run of our own documented one-liner (the upgrade and key-rotation
    # paths), telling the operator their URL was rejected and inviting them to
    # move a working config aside.
    configured_url="${EMISAR_URL:-}"
    case "${configured_url}" in
      https://*) configured_url="wss://${configured_url#https://}";;
      http://*)  configured_url="ws://${configured_url#http://}";;
    esac
    if [ -n "${configured_url}" ] && ! grep -qF "${configured_url}" "${cfg}" 2>/dev/null; then
      warn "EMISAR_URL='${EMISAR_URL}' was NOT applied: ${cfg} already exists and keeps its"
      warn "current cloud.url. Edit it by hand, or move the file aside and re-run."
    fi
    NEEDS_CONFIGURATION=0
  fi
  chmod 640 "${cfg}"
  chown "root:${SERVICE_GROUP}" "${cfg}" 2>/dev/null || chown root:root "${cfg}"

  local env="${ETC_DIR}/runner.env"
  if [ ! -f "${env}" ]; then
    log "writing runner.env stub to ${env}"
    # Create the file 0600 from the first byte (umask in a subshell) so
    # EMISAR_ENROLLMENT_KEY is never momentarily world-readable. The previous
    # write-then-chmod left a brief race window where it was 0644.
    ( umask 077 && runner_env_skeleton > "${env}" )
    # Belt-and-suspenders in case a restrictive umask wasn't honoured.
    chmod 600 "${env}"
  elif [ "${ENROLLMENT_KEY_UPDATE}" = "1" ]; then
    backup_enrollment_state
    write_enrollment_key
  fi
  chmod 600 "${env}"
  chown "root:${SERVICE_GROUP}" "${env}" 2>/dev/null || chown root:root "${env}"

}

STAGED_BINARY=""
BACKUP_BINARY=""
BINARY_ACTIVATED=0
SERVICE_WAS_RUNNING=0
# Set when THIS run created the service unit — a fresh install, not an upgrade.
# `restore_previous_service` only restarts a service that was already running,
# so on a fresh install that failed, nothing undid the enablement: the binary was
# removed and the enabled unit stayed, leaving systemd retrying a missing
# ExecStart on every boot forever. The header promises nothing partially applied
# is left in a "running but broken" state.
SERVICE_UNIT_CREATED=0
INSTALL_TRANSACTION=0
RECEIPT_PREEXISTED=0
INSTALL_RECEIPT_PATH="${ETC_DIR}/install-receipt"
INSTALL_RECEIPT_LOCATOR="${BIN_DIR}/.emisar-install-receipt"

# The updater does not infer ownership from a path. This receipt is the
# installer saying which exact binary and service paths it owns; the CLI accepts
# it only when this file and its directory chain remain root-owned and not
# writable by another user. A tiny locator beside the binary points here so
# custom --etc-dir installations remain discoverable.
write_install_receipt() {
  local value receipt_tmp locator_tmp owner="root:${SERVICE_GROUP}"
  if [ "${OS}" = "darwin" ]; then owner="root:wheel"; fi

  for value in "${REPO}" "${BIN_DIR}/emisar" "${ETC_DIR}" "${DATA_DIR}" "${LOG_DIR}" \
    "${SERVICE_USER}" "${SERVICE_GROUP}" "${INIT}"; do
    case "${value}" in
      *$'\n'*|*$'\r'*) die "install receipt values must not contain newlines" ;;
    esac
  done

  receipt_tmp="$(mktemp "${INSTALL_RECEIPT_PATH}.tmp.XXXXXX")" || \
    die "could not stage ${INSTALL_RECEIPT_PATH}"
  chmod 600 "${receipt_tmp}"
  cat >"${receipt_tmp}" <<EOF
schema=1
manager=install.sh
repository=${REPO}
binary=${BIN_DIR}/emisar
etc_dir=${ETC_DIR}
data_dir=${DATA_DIR}
log_dir=${LOG_DIR}
service_user=${SERVICE_USER}
service_group=${SERVICE_GROUP}
init=${INIT}
EOF
  chown "${owner}" "${receipt_tmp}" 2>/dev/null || chown root:root "${receipt_tmp}"
  mv -f "${receipt_tmp}" "${INSTALL_RECEIPT_PATH}" || {
    rm -f "${receipt_tmp}"
    die "could not activate ${INSTALL_RECEIPT_PATH}"
  }

  locator_tmp="$(mktemp "${INSTALL_RECEIPT_LOCATOR}.tmp.XXXXXX")" || \
    die "could not stage ${INSTALL_RECEIPT_LOCATOR}"
  chmod 644 "${locator_tmp}"
  printf '%s\n' "${INSTALL_RECEIPT_PATH}" >"${locator_tmp}"
  chown "${owner}" "${locator_tmp}" 2>/dev/null || chown root:root "${locator_tmp}"
  mv -f "${locator_tmp}" "${INSTALL_RECEIPT_LOCATOR}" || {
    rm -f "${locator_tmp}"
    die "could not activate ${INSTALL_RECEIPT_LOCATOR}"
  }
  log "recorded installer ownership at ${INSTALL_RECEIPT_PATH}"
}

rollback_install_receipt() {
  [ "${RECEIPT_PREEXISTED}" = "0" ] || return 0
  rm -f "${INSTALL_RECEIPT_PATH}" "${INSTALL_RECEIPT_LOCATOR}"
}

stage_binary() {
  local src="$1/emisar" ver_output expected
  if [ ! -f "${src}" ]; then
    die "expected binary at ${src} but it is missing"
  fi
  mkdir -p "${BIN_DIR}"
  chmod 755 "${BIN_DIR}"
  STAGED_BINARY="${BIN_DIR}/.emisar.new.$$"
  log "staging binary at ${STAGED_BINARY}"
  install -m 0755 "${src}" "${STAGED_BINARY}"
  # Use the one-line machine contract the release workflow verifies. The
  # human `version` command deliberately includes build metadata.
  ver_output=$("${STAGED_BINARY}" --version 2>/dev/null) || \
    die "staged binary did not respond to --version"
  expected="emisar version ${VERSION#runner-v}"
  [ "${ver_output}" = "${expected}" ] || \
    die "staged binary reported '${ver_output}', expected '${expected}'"
  log "verified: ${ver_output}"
}

# A corrupt durable dispatch log makes the upgraded runner refuse to start (by
# design: it cannot prove at-most-once execution against unreadable state).
# Catch it with the STAGED binary before the running service is touched, so an
# upgrade never converts a working host into a crash-looping one. Readable
# pre-v0.12 state is fine — the new runner migrates it forward on boot.
check_dispatch_log() {
  # Older binaries don't have the verb; nothing to check against. Probe the
  # subcommand LISTING — `state check-dispatch-log --help` on an old binary
  # prints the parent's help and exits 0, so its exit code proves nothing.
  "${STAGED_BINARY}" state --help 2>/dev/null | grep -q "check-dispatch-log" || return 0
  if "${STAGED_BINARY}" state check-dispatch-log --data-dir "${DATA_DIR}" >/dev/null 2>&1; then
    return 0
  fi
  local logfile="${DATA_DIR}/dispatches.jsonl"
  [ -f "${logfile}" ] || logfile="${DATA_DIR}/dedup.jsonl"
  if [ "${QUARANTINE_DISPATCH_LOG:-0}" = "1" ]; then
    local quarantined
    quarantined="${logfile}.corrupt-$(date +%Y%m%d%H%M%S)"
    mv "${logfile}" "${quarantined}"
    warn "dispatch log was unreadable; quarantined it at ${quarantined}"
    warn "the runner starts a clean dispatch log on next boot"
    return 0
  fi
  warn "the durable dispatch log at ${logfile} is unreadable; the upgraded runner would refuse to start over it"
  warn "options:"
  warn "  1) quarantine it and start clean:  sudo mv ${logfile} ${logfile}.corrupt"
  warn "  2) re-run this installer with QUARANTINE_DISPATCH_LOG=1 to do that automatically"
  warn "  3) investigate first — nothing changes while the current runner keeps running"
  die "refusing to upgrade over unreadable dispatch state (the current install is untouched)"
}

activate_binary() {
  local target="${BIN_DIR}/emisar"
  if [ -e "${target}" ]; then
    BACKUP_BINARY="${BIN_DIR}/.emisar.previous.$$"
    mv "${target}" "${BACKUP_BINARY}"
  fi
  mv "${STAGED_BINARY}" "${target}"
  STAGED_BINARY=""
  BINARY_ACTIVATED=1
  log "installed binary to ${target}"
}

rollback_binary() {
  local target="${BIN_DIR}/emisar"
  [ -z "${STAGED_BINARY}" ] || rm -f "${STAGED_BINARY}"
  if [ "${BINARY_ACTIVATED}" = "1" ]; then
    rm -f "${target}"
    if [ -n "${BACKUP_BINARY}" ] && [ -e "${BACKUP_BINARY}" ]; then
      mv "${BACKUP_BINARY}" "${target}"
      log "restored previous binary after failed upgrade"
    fi
  fi
}

discard_binary_backup() {
  [ -z "${BACKUP_BINARY}" ] || rm -f "${BACKUP_BINARY}"
  BACKUP_BINARY=""
}

# install_default_packs installs the starter packs from the bundle shipped
# inside this tarball (offline — no registry round-trip).
# The full catalog is fetched on demand later via `emisar pack install
# <name>`. $1 is the extracted tarball root.
install_default_packs() {
  local bundle="$1/packs"
  local dst="${ETC_DIR}/packs"

  if [ ! -d "${bundle}" ]; then
    warn "no bundled packs in this tarball; skipping starter packs"
    return 0
  fi

  local wanted selected=()

  if [ "${INIT}" = "none" ]; then
    # Binary-only installs commonly run in Cloud Shell / CI / containers,
    # where the image has many client CLIs installed but is not the host
    # being managed. Do not treat that toolbelt as a service inventory.
    for wanted in linux-core debugging; do
      [ -d "${bundle}/${wanted}" ] && selected+=("${wanted}")
    done
  else
    # Let the runner pick which bundled packs suit this host: `pack suggest`
    # inspects the host (binaries on PATH, in standard dirs, or running as a
    # process) and matches the bundle's declared requirements — data-driven,
    # so a new bundled pack needs no edit here. Intersect with what's bundled
    # in case catalog and bundle ever drift; fall back to the OS-agnostic
    # core if suggest can't run.
    while IFS= read -r wanted; do
      [ -n "${wanted}" ] && [ -d "${bundle}/${wanted}" ] && selected+=("${wanted}")
    done < <("${BIN_DIR}/emisar" pack suggest --catalog "${bundle}" --names-only 2>/dev/null || true)
  fi

  if [ ${#selected[@]} -eq 0 ]; then
    for wanted in linux-core debugging; do
      [ -d "${bundle}/${wanted}" ] && selected+=("${wanted}")
    done
  fi

  if [ ${#selected[@]} -eq 0 ]; then
    return 0
  fi

  local prompt="install starter packs for this host (${selected[*]})?"
  if [ "${INIT}" = "none" ]; then
    prompt="install core starter packs (${selected[*]})? (--no-service skips host-detected packs)"
  fi
  if ! confirm "${prompt}"; then
    log "skipping starter packs — add them later with: sudo ${BIN_DIR}/emisar pack install <name>"
    return 0
  fi

  mkdir -p "${dst}"
  local p
  for p in "${selected[@]}"; do
    if "${BIN_DIR}/emisar" pack install "${bundle}/${p}" --dest "${dst}" --force >/dev/null 2>&1; then
      log "installed pack ${p}"
    else
      warn "failed to install pack ${p} (continuing)"
    fi
  done

}

# install_suggested_packs queries the full registry catalog for packs that
# match this host (running processes, listening ports, and installed
# binaries) and offers to install them now — so a host running Nomad,
# Consul, Postgres, etc. gets the matching packs in one step instead of
# hunting for them. Network-dependent: if the catalog can't be reached it
# says so and points at `emisar pack suggest`; it never blocks the install.
install_suggested_packs() {
  local dst="${ETC_DIR}/packs"
  local out

  if [ "${INIT}" = "none" ]; then
    log "binary-only install: skipping host-detected pack suggestions; add packs later with: sudo ${BIN_DIR}/emisar pack install <name>"
    return 0
  fi

  # `if cmd` (not `cmd || true`) so set -e doesn't abort here, and so we can
  # tell "catalog unreachable" (non-zero exit) from "nothing matched" (zero
  # exit, empty output) — only the former warrants the can't-reach note.
  if ! out="$("${BIN_DIR}/emisar" pack suggest --packs-dir "${dst}" --names-only 2>/dev/null)"; then
    log "couldn't reach the pack catalog — run '${BIN_DIR}/emisar pack suggest' later for host-matched packs"
    return 0
  fi
  [ -n "${out}" ] || return 0

  local names
  names="$(printf '%s' "${out}" | tr '\n' ' ')"
  names="${names% }"

  if ! confirm "install host-matched pack recommendations (${names})?"; then
    log "skipping — add them later with: sudo ${BIN_DIR}/emisar pack install <name>"
    return 0
  fi

  mkdir -p "${dst}"
  local n
  for n in ${out}; do
    if "${BIN_DIR}/emisar" pack install "${n}" --dest "${dst}" --force >/dev/null 2>&1; then
      log "installed pack ${n}"
    else
      warn "failed to install pack ${n} (continuing)"
    fi
  done

}

# install_named_packs installs an explicit, operator-given pack set
# (--packs / EMISAR_PACKS): no host detection, no prompt. Each name is
# installed from the bundle if present (offline), else fetched from the
# registry. Invalid names and individual failures warn but never abort.
# An explicit-but-empty set installs nothing — and still suggests nothing.
install_named_packs() {
  local bundle="$1/packs"
  local dst="${ETC_DIR}/packs"

  # Split the explicit list the way the loop below does. An empty result
  # (EMISAR_PACKS='' / ' ' / ',' — e.g. a templated value that rendered
  # empty) is an explicit "no extra packs now": install nothing, and
  # crucially do NOT fall back to host detection or suggestions.
  local requested
  requested="$(printf '%s' "${PRE_PACKS}" | tr ',' ' ')"
  if [ -z "$(printf '%s' "${requested}" | tr -d '[:space:]')" ]; then
    log "EMISAR_PACKS is set but empty — installing no packs (explicit set); add later with: sudo ${BIN_DIR}/emisar pack install <name>"
    return 0
  fi

  mkdir -p "${dst}"
  local p src origin
  for p in ${requested}; do
    # A pack name is a single path segment; reject anything that could
    # escape the bundle dir or malform the registry URL (we run as root).
    case "${p}" in
      ''|.|..|-*|.*|*..*|*[!a-zA-Z0-9._-]*)
        warn "skipping invalid pack name '${p}'"; continue;;
    esac

    if [ -d "${bundle}/${p}" ]; then
      src="${bundle}/${p}"; origin="bundled"
    else
      src="${p}"; origin="registry"
    fi

    if "${BIN_DIR}/emisar" pack install "${src}" --dest "${dst}" --force >/dev/null 2>&1; then
      log "installed pack ${p} (${origin})"
    else
      warn "failed to install pack ${p} (${origin}) — continuing"
    fi
  done

}

# A strict runner can reject an older malformed pack before `pack update` gets
# a chance to replace it. The updater inspects packs independently, so use it
# once before host detection and then require the complete tree to load.
repair_installed_packs() {
  local dst="${ETC_DIR}/packs"
  [ -d "${dst}" ] || return 0
  if "${BIN_DIR}/emisar" pack list --packs-dir "${dst}" >/dev/null 2>&1; then
    return 0
  fi

  warn "installed pack validation failed; repairing official packs from the registry"
  "${BIN_DIR}/emisar" pack update --packs-dir "${dst}" || \
    die "could not repair installed packs; fix or remove the invalid local pack shown above"
}

verify_installed_packs() {
  local dst="${ETC_DIR}/packs" output
  [ -d "${dst}" ] || return 0
  if ! output=$("${BIN_DIR}/emisar" pack list --packs-dir "${dst}" 2>&1); then
    die "installed pack validation failed:
${output}"
  fi
}

secure_pack_tree() {
  local dst="${ETC_DIR}/packs"
  [ -d "${dst}" ] || return 0

  # Packs are administrator-trusted executable content. The runner only needs
  # the normalized read/execute modes written by `pack install`; ownership stays
  # outside the service account so a compromised runner cannot rewrite a future
  # action. Running this on every upgrade also repairs older installations.
  case "${OS}" in
    linux)  chown -R root:root "${dst}";;
    darwin) chown -R root:wheel "${dst}";;
  esac
}

install_systemd() {
  local unit="/etc/systemd/system/emisar.service"
  [ -e "${unit}" ] || SERVICE_UNIT_CREATED=1
  log "writing ${unit}"
  systemd_unit > "${unit}"
  chmod 644 "${unit}"
  systemctl daemon-reload
  systemctl enable emisar.service >/dev/null
}

install_launchd() {
  local plist="/Library/LaunchDaemons/com.emisar.runner.plist"
  local runner="${ETC_DIR}/run-launchd.sh"
  [ -e "${plist}" ] || SERVICE_UNIT_CREATED=1
  log "writing ${runner}"
  launchd_runner_script > "${runner}"
  chown root:wheel "${runner}"
  chmod 700 "${runner}"
  log "writing ${plist}"
  launchd_plist > "${plist}"
  chown root:wheel "${plist}"
  chmod 644 "${plist}"
}

start_service() {
  if [ "${INIT}" = "none" ]; then
    # No service unit to start — the operator runs the binary directly.
    return 0
  fi
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
      log "starting emisar.service"
      systemctl restart emisar.service
      # Type=simple can report a successful start immediately before the
      # process exits. Give startup validation time to fail, then require the
      # service to be genuinely active rather than auto-restarting.
      sleep 2
      require_systemd_service_active
      ;;
    launchd)
      local plist="/Library/LaunchDaemons/com.emisar.runner.plist"
      # bootout is the idempotent way to (re)load; ignore missing-target.
      launchctl bootout system "${plist}" 2>/dev/null || true
      log "loading com.emisar.runner"
      launchctl bootstrap system "${plist}"
      # Verify, like the systemd arm above. This was `|| true`, so a daemon that
      # failed to load reported a successful install — and because
      # SERVICE_STARTED stayed 0, the summary then told the operator to run the
      # very bootstrap this just ran, which answers "Operation already in
      # progress" on a healthy machine. macOS is the evaluation path, so that is
      # the first thing a new operator sees.
      sleep 2
      if ! launchctl print system/com.emisar.runner >/dev/null 2>&1; then
        launchctl print system/com.emisar.runner || true
        die "com.emisar.runner did not stay loaded"
      fi
      SERVICE_STARTED=1
      ;;
  esac
}

require_systemd_service_active() {
  local state
  state="$(systemctl is-active emisar.service 2>/dev/null || true)"
  if [ "${state}" != "active" ]; then
    systemctl --no-pager --full status emisar.service || true
    die "emisar.service did not stay active (systemd state: ${state:-unknown})"
  fi
  SERVICE_STARTED=1
  systemctl --no-pager --full status emisar.service || true
}

stop_service_if_running() {
  case "${INIT}" in
    systemd)
      if systemctl is-active --quiet emisar.service; then
        SERVICE_WAS_RUNNING=1
        log "stopping emisar.service for upgrade"
        systemctl stop emisar.service
      fi
      ;;
    launchd)
      local plist="/Library/LaunchDaemons/com.emisar.runner.plist"
      if launchctl print system/com.emisar.runner >/dev/null 2>&1; then
        SERVICE_WAS_RUNNING=1
        log "unloading com.emisar.runner for upgrade"
        launchctl bootout system "${plist}" 2>/dev/null || true
      fi
      ;;
  esac
}

restore_previous_service() {
  [ "${SERVICE_WAS_RUNNING}" = "1" ] || return 0
  case "${INIT}" in
    systemd) systemctl start emisar.service ;;
    launchd)
      launchctl bootstrap system /Library/LaunchDaemons/com.emisar.runner.plist
      ;;
  esac
}

# Undo a service unit THIS run created. Only for a fresh install: an upgrade's
# unit predates us and belongs to the installation we are restoring.
rollback_service() {
  [ "${SERVICE_UNIT_CREATED}" = "1" ] || return 0
  case "${INIT}" in
    systemd)
      systemctl disable --now emisar.service >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/emisar.service
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    launchd)
      launchctl bootout system/com.emisar.runner >/dev/null 2>&1 || true
      rm -f /Library/LaunchDaemons/com.emisar.runner.plist
      ;;
  esac
  log "removed the service unit this run created"
}

finish_install() {
  local rc=$1
  trap - EXIT HUP INT TERM
  set +e
  if [ "$rc" -ne 0 ] && [ "${INSTALL_TRANSACTION}" = "1" ]; then
    rollback_binary
    restore_enrollment_state
    rollback_service
    rollback_install_receipt
    restore_previous_service
    warn "installation failed; restored the previous runner and service state"
  fi
  [ -z "${tmp:-}" ] || rm -rf "${tmp}"
  exit "$rc"
}

# -----------------------------------------------------------------------
# Install + uninstall flows
# -----------------------------------------------------------------------

do_install() {
  # Reject ambiguous automation before resolving or downloading a release and
  # before touching a running service. Pack suggestions are recommendations,
  # not consent to mutate an unattended host.
  require_explicit_unattended_packs
  require_root_and_tools
  log "install target: ${OS}/${ARCH} via ${INIT}"
  if [ -n "${PREVERIFIED_BUNDLE}" ]; then
    log "preverified release: ${VERSION}"
  elif [ -z "${VERSION}" ]; then
    VERSION="$(resolve_latest_version)" || die "could not resolve latest version"
    log "latest release: ${VERSION}"
  else
    log "pinned release: ${VERSION}"
  fi
  [[ "${VERSION}" =~ ^runner-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "release version must match runner-vMAJOR.MINOR.PATCH (got '${VERSION}')"
  if [ -z "${PREVERIFIED_BUNDLE}" ]; then
    require_immutable_release "${VERSION}"
  fi

  local prompt
  if [ "${INIT}" = "none" ]; then
    prompt="install emisar ${VERSION} to ${BIN_DIR}/emisar (binary only, no service)?"
  else
    prompt="install emisar ${VERSION} to ${BIN_DIR}/emisar (and configure as a service)?"
  fi
  if ! confirm "${prompt}"; then
    die "aborted by user"
  fi

  prepare_enrollment_key_update

  # `tmp` is intentionally global — the EXIT trap fires after this
  # function returns, by which point a `local tmp` would be out of scope
  # and `set -u` would trip on the bare reference. Default-empty in the
  # trap so an early exit before mktemp doesn't print "unbound variable".
  # sudo commonly preserves TMPDIR, and this path always runs as root: a
  # root-owned child of a non-sticky user-owned parent is still replaceable
  # by that user, so the download dir is pinned under /tmp.
  tmp="$(mktemp -d /tmp/emisar-install.XXXXXX)"
  # A bare signal fires the EXIT trap with $?=0, which finish_install's
  # rc-guard reads as success — convert HUP/INT/TERM into the conventional
  # 128+signum exit so a Ctrl-C mid-swap still rolls back.
  trap 'finish_install $?' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local extracted
  if [ -n "${PREVERIFIED_BUNDLE}" ]; then
    extracted="${PREVERIFIED_BUNDLE}"
  else
    extracted="$(download_release "${VERSION}" "${tmp}")"
  fi

  # Download, stage, and execute the new binary before interrupting a running
  # service. Architecture/version failures leave the current runner untouched.
  stage_binary "${extracted}"
  check_dispatch_log
  INSTALL_TRANSACTION=1
  if [ -e "${INSTALL_RECEIPT_PATH}" ] || [ -e "${INSTALL_RECEIPT_LOCATOR}" ]; then
    RECEIPT_PREEXISTED=1
  fi
  stop_service_if_running

  # --no-service skips the daemon user — without an init unit, the
  # binary runs as whoever invokes it. Keeping the system user would
  # leave a stray uid behind on hosts where nobody's about to use it.
  if [ "${INIT}" != "none" ]; then
    case "${OS}" in
      linux)  ensure_user_linux;;
      darwin) ensure_user_macos;;
    esac
  fi

  ensure_dirs
  activate_binary
  if [ -n "${PREVERIFIED_BUNDLE}" ]; then
    log "preserving installed packs (runner binary update)"
  else
    repair_installed_packs
    # EMISAR_PACKS set (even empty) or --packs given ⇒ the pack set is
    # explicit: install exactly it, never host-detect or suggest.
    if [ "${PACKS_EXPLICIT}" = "1" ]; then
      install_named_packs "${extracted}"
    else
      install_default_packs "${extracted}"
      install_suggested_packs
    fi
  fi
  verify_installed_packs
  secure_pack_tree
  drop_config_skeleton

  case "${INIT}" in
    systemd) install_systemd;;
    launchd) install_launchd;;
    none)    log "skipping service unit (--no-service)";;
  esac

  start_service
  write_install_receipt

  discard_binary_backup
  INSTALL_TRANSACTION=0

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
EOF

  # If EMISAR_URL + EMISAR_ENROLLMENT_KEY came in via env, drop_config_skeleton
  # already wrote them — no manual edit needed. Otherwise prompt for it.
  if [ "${NEEDS_CONFIGURATION:-1}" = "1" ]; then
    cat <<EOF

Next steps:
  1. Edit ${ETC_DIR}/config.yaml — set runner.group, cloud.url, etc.
  2. Edit ${ETC_DIR}/runner.env — set EMISAR_ENROLLMENT_KEY=emkey-enroll-...
EOF
  else
    cat <<EOF

Pre-configured from install env (EMISAR_URL + EMISAR_ENROLLMENT_KEY).
Edit ${ETC_DIR}/config.yaml to tighten runner.group / labels later.
EOF
  fi

  case "${INIT}" in
    systemd)
      if [ "${SERVICE_STARTED}" = "1" ]; then
        cat <<EOF

The service is running. Check status / logs:
  sudo systemctl status emisar
  sudo journalctl -u emisar -f
EOF
      else
        cat <<EOF
  3. Start the service:
       sudo systemctl start emisar
     Or restart after editing config:
       sudo systemctl restart emisar
  4. Check status / logs:
       sudo systemctl status emisar
       sudo journalctl -u emisar -f
EOF
      fi
      ;;
    none)
      if [ "${NEEDS_CONFIGURATION:-1}" = "1" ]; then
        cat <<EOF
  3. Run the binary directly (no service was installed):
       ${BIN_DIR}/emisar connect --config ${ETC_DIR}/config.yaml
     For a one-off connect test, pass the key inline:
       EMISAR_ENROLLMENT_KEY=emkey-... ${BIN_DIR}/emisar connect --config ${ETC_DIR}/config.yaml
EOF
      else
        # No systemd to load runner.env, so we source it in the same
        # shell that starts the binary. set -a/+a marks subsequent
        # assignments as exported, the dot-source loads the KEY=VALUE
        # lines, then set +a stops auto-exporting before running the
        # binary.
        cat <<EOF

Run the binary directly (no service was installed):
  sudo bash -c 'set -a; . ${ETC_DIR}/runner.env; set +a; ${BIN_DIR}/emisar connect --config ${ETC_DIR}/config.yaml'
EOF
      fi
      ;;
    launchd)
      # Only tell them to load it if we did not. Printing this unconditionally
      # meant a successful install ended by instructing the operator to run a
      # bootstrap that then failed with "Operation already in progress".
      if [ "${SERVICE_STARTED}" = "1" ]; then
        cat <<EOF
  Check logs:
       tail -f ${LOG_DIR}/emisar.err.log ${LOG_DIR}/emisar.out.log
EOF
      else
        cat <<EOF
  3. Load the LaunchDaemon:
       sudo launchctl bootstrap system /Library/LaunchDaemons/com.emisar.runner.plist
  4. Check logs:
       tail -f ${LOG_DIR}/emisar.err.log ${LOG_DIR}/emisar.out.log
EOF
      fi
      ;;
  esac

  # Collect installed pack names via a glob (portable + avoids parsing
  # `ls`); each immediate child dir of the packs dir is one pack id.
  local installed="" d
  for d in "${ETC_DIR}/packs"/*/; do
    [ -d "$d" ] || continue
    installed+="$(basename "$d") "
  done

  cat <<EOF

Action packs:
  Installed:  ${installed:-(none)}
  Suggest:    ${BIN_DIR}/emisar pack suggest             (host-matched packs for what's running)
  Add more:   sudo ${BIN_DIR}/emisar pack install <name>
  Remove:     sudo ${BIN_DIR}/emisar pack uninstall <name>
  Reload:     automatic via SIGHUP; commands print a manual fallback if needed
  Browse:     https://emisar.dev/packs
EOF

  echo
  # \$0 is "bash" when run as `curl ... | sudo bash`, so don't print that.
  # Show the canonical re-curl form instead.
  echo "Uninstall:  curl -fsSL https://emisar.dev/install.sh | sudo bash -s -- --uninstall"
  echo "Update:     sudo ${BIN_DIR}/emisar update"
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

  remove_runner_token

  if [ -f "${BIN_DIR}/emisar" ]; then
    log "removing ${BIN_DIR}/emisar"
    rm -f "${BIN_DIR}/emisar"
  fi
  rm -f "${INSTALL_RECEIPT_LOCATOR}" "${INSTALL_RECEIPT_PATH}"

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
  ${DATA_DIR} (dispatch log + signing nonces; token + identity removed)
  ${LOG_DIR}  (security log)
EOF
  fi

  log "uninstalled"
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------

detect_target

case "${MODE}" in
  install)   do_install;;
  uninstall) do_uninstall;;
  *) die "internal: unknown mode ${MODE}";;
esac

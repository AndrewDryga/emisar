#!/usr/bin/env bash
# install-mcp.sh — Install or upgrade the emisar-mcp stdio bridge.
#
# The bridge is a single self-contained Go binary that an MCP-aware
# client (Claude Desktop, Claude Code, Cursor, Gemini CLI, Codex CLI,
# Grok, …) launches as a child process and talks to over stdin/stdout. It
# proxies JSON-RPC frames to the emisar control plane's
# `/api/mcp/rpc` endpoint and forwards responses back.
#
# Usage:
#
#   curl -sSL https://emisar.dev/install-mcp.sh | sudo bash
#
#   # Pin a version:
#   curl -sSL https://.../install-mcp.sh | sudo bash -s -- --version mcp-v0.1.0
#
#   # Install to a per-user location (no sudo):
#   curl -sSL https://.../install-mcp.sh | INSTALL_DIR=$HOME/.local/bin bash
#
# The script is idempotent. It does not register a service. After
# installing, an interactive run scans for local LLM clients (Claude
# Code, Claude Desktop, Cursor, Gemini CLI, Codex CLI, OpenClaw,
# OpenCode, Windsurf, Pi, Copilot CLI, Zed, Hermes, Goose) and offers
# to add emisar to each — asking per client; a non-interactive or --yes
# run skips that entirely. The API keys come from a browser approval
# (the script prints an approval link; no key is ever typed or copied)
# and land straight in the client configs, pointed at EMISAR_URL.
# Manual per-client snippets stay available on the portal's
# /app/agents page.

set -Eeuo pipefail

REPO="${EMISAR_REPO:-andrewdryga/emisar}"
# The portal this bridge talks to. A self-hosted or dev portal's install
# command overrides it (the client configs written below carry it).
EMISAR_URL="${EMISAR_URL:-https://emisar.dev}"
EMISAR_URL="${EMISAR_URL%/}"
INSTALL_DIR="${INSTALL_DIR:-}"
INSTALL_DIR_EXPLICIT=0
[ -n "${INSTALL_DIR}" ] && INSTALL_DIR_EXPLICIT=1
VERSION="${VERSION:-}"     # empty → latest mcp-v* tag

usage() {
  cat <<'USAGE'
emisar-mcp installer

Usage: install-mcp.sh [--version TAG] [--install-dir DIR] [--yes]

Flags:
  --version TAG       Install a specific MCP release. Accepts
                      `mcp-vX.Y.Z`, `vX.Y.Z`, or bare `X.Y.Z`
                      (auto-prefixed with `mcp-v`). Default: latest.
  --install-dir DIR   Where to place the `emisar-mcp` binary. By default,
                      existing user-local and system installs are upgraded;
                      a fresh install uses /usr/local/bin.
  --yes               Skip the confirmation prompt and the interactive
                      LLM-client setup.
  --help              This message.

Env vars accepted: VERSION, INSTALL_DIR, EMISAR_REPO, EMISAR_GITHUB_TOKEN,
ASSUME_YES, EMISAR_URL (the portal the bridge talks to; default
https://emisar.dev — a self-hosted portal's install command sets it).
USAGE
}

ASSUME_YES="${ASSUME_YES:-0}"

require_value() {
  local flag="$1"
  if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == -* ]]; then
    printf 'flag %s requires a value\n' "$flag" >&2
    usage >&2
    exit 2
  fi
}

normalize_version() {
  case "$1" in
    mcp-v*) printf '%s\n' "$1";;
    v*)     printf 'mcp-%s\n' "$1";;
    *)      printf 'mcp-v%s\n' "$1";;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      require_value "$@"
      VERSION="$(normalize_version "$2")"
      shift 2
      ;;
    --install-dir)
      require_value "$@"
      INSTALL_DIR="$2"
      INSTALL_DIR_EXPLICIT=1
      shift 2
      ;;
    --yes|-y)      ASSUME_YES=1; shift;;
    --help|-h)     usage; exit 0;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2;;
  esac
done

log()  { printf '\033[1;34m[install-mcp]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install-mcp]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install-mcp]\033[0m %s\n' "$*" >&2; exit 1; }

github_api() {
  if [ -n "${EMISAR_GITHUB_TOKEN:-}" ]; then
    curl -fsSL -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer ${EMISAR_GITHUB_TOKEN}" "$@"
  else
    # Bash 3.2 (the macOS system Bash) treats an expanded empty local array as
    # unbound under `set -u`, so keep the no-token path array-free.
    curl -fsSL -H 'Accept: application/vnd.github+json' "$@"
  fi
}

require_immutable_release() {
  local version="$1" release
  release=$(github_api \
    "https://api.github.com/repos/${REPO}/releases/tags/${version}") \
    || die "could not verify release metadata for ${version}"
  grep -Eq '"immutable"[[:space:]]*:[[:space:]]*true' <<<"$release" || \
    die "release ${version} is mutable and is no longer trusted; install the latest immutable MCP release"
}

# Same TTY-fallback prompt the runner installer uses — curl|bash makes
# stdin the script content, not a terminal, so a plain `read` consumes
# the next line of the script. See install.sh for the longer rationale.
confirm() {
  if [ "$ASSUME_YES" = "1" ]; then return 0; fi
  if [ -t 0 ]; then
    printf '%s [y/N] ' "$1"
    read -r reply || reply=""
  elif { exec 3</dev/tty; } 2>/dev/null; then
    printf '%s [y/N] ' "$1" >/dev/tty
    read -r reply <&3 || reply=""
    exec 3<&-
  else
    return 0
  fi
  case "$reply" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac
}

# ---------------------------------------------------------------------
# Detect OS + arch
# ---------------------------------------------------------------------

case "$(uname -s)" in
  Linux)  OS=linux;;
  Darwin) OS=darwin;;
  *) die "unsupported OS: $(uname -s) (linux + darwin only)";;
esac

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64;;
  arm64|aarch64) ARCH=arm64;;
  *) die "unsupported arch: $(uname -m) (amd64 + arm64 only)";;
esac

invoking_user_home() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    if command -v getent >/dev/null 2>&1; then
      getent passwd "${SUDO_USER}" | cut -d: -f6
      return
    fi
    if command -v dscl >/dev/null 2>&1; then
      dscl . -read "/Users/${SUDO_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
      return
    fi
    case "${OS}" in
      darwin) printf '/Users/%s\n' "${SUDO_USER}" ;;
      *) printf '/home/%s\n' "${SUDO_USER}" ;;
    esac
    return
  fi
  printf '%s\n' "${HOME}"
}

# A prior no-sudo install is common, while the portal's one-line upgrade uses
# sudo. Upgrade every conventional location that already contains the bridge
# so an LLM client cannot keep launching a stale copy after a successful run.
resolve_install_dirs() {
  local user_home="$1"
  local system_dir="${2:-/usr/local/bin}"
  local dirs=""
  local candidate

  for candidate in "${user_home}/.local/bin" "${system_dir}"; do
    if [ -x "${candidate}/emisar-mcp" ]; then
      dirs="${dirs}${dirs:+
}${candidate}"
    fi
  done
  if [ -z "${dirs}" ]; then
    dirs="${system_dir}"
  fi
  printf '%s\n' "${dirs}"
}

make_temp_dir() {
  local parent="${TMPDIR:-/tmp}"

  # sudo commonly preserves TMPDIR. A root-owned child is still replaceable by
  # the owner of a non-sticky parent, so privileged downloads always use /tmp.
  if [ "$(id -u)" -eq 0 ]; then
    parent=/tmp
  fi
  mktemp -d "${parent%/}/emisar-mcp-install.XXXXXX"
}

if [ "${INSTALL_DIR_EXPLICIT}" = "0" ]; then
  user_home=$(invoking_user_home)
  install_dirs=$(resolve_install_dirs "${user_home}")
else
  install_dirs="${INSTALL_DIR}"
fi

log "install target: ${OS}/${ARCH}"
while IFS= read -r dir; do
  log "  → ${dir}/emisar-mcp"
done <<<"${install_dirs}"

# ---------------------------------------------------------------------
# Resolve version
# ---------------------------------------------------------------------

if [ -z "${VERSION}" ]; then
  log "querying latest mcp-v* release"
  VERSION=$(
    github_api \
      "https://api.github.com/repos/${REPO}/releases?per_page=100" \
      | grep -oE '"tag_name":[[:space:]]*"mcp-v[0-9]+\.[0-9]+\.[0-9]+"' \
      | head -1 \
      | sed -E 's/.*"(mcp-v[^"]+)".*/\1/'
  ) || die "could not query GitHub releases API"
  [ -n "${VERSION}" ] || die "no mcp-v* release found yet"
  log "latest release: ${VERSION}"
else
  log "pinned release: ${VERSION}"
fi
[[ "${VERSION}" =~ ^mcp-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  die "release version must match mcp-vMAJOR.MINOR.PATCH (got '${VERSION}')"
require_immutable_release "${VERSION}"

VERSION_NUM="${VERSION#mcp-v}"
TAR_NAME="emisar-mcp-${VERSION_NUM}-${OS}-${ARCH}"
TARBALL="${TAR_NAME}.tar.gz"
BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"

if ! confirm "install emisar-mcp ${VERSION} to the listed target(s)?"; then
  die "aborted by user"
fi

# ---------------------------------------------------------------------
# Download + verify
# ---------------------------------------------------------------------

tmp="$(make_temp_dir)" || die "could not create a private temporary directory"
if [ ! -d "${tmp}" ] || [ -L "${tmp}" ] || [ ! -O "${tmp}" ] || ! chmod 0700 "${tmp}"; then
  rm -rf -- "${tmp}"
  die "temporary directory was not a private directory owned by the installer"
fi
staged_paths=""
backup_paths=""
activated_paths=""
installed_paths=""
transaction_active=0

rollback_installations() {
  local bin_dst bin_backup path
  local expected_backup
  local failed=0

  if [ -n "${activated_paths}" ]; then
    while IFS= read -r bin_dst; do
      [ -n "${bin_dst}" ] || continue
      bin_backup="${bin_dst%/*}/.emisar-mcp.old.$$"
      expected_backup=0
      if [ -n "${backup_paths}" ]; then
        while IFS= read -r path; do
          if [ "${path}" = "${bin_backup}" ]; then
            expected_backup=1
            break
          fi
        done <<<"${backup_paths}"
      fi
      if [ -e "${bin_backup}" ]; then
        if [ "${bin_backup}" -ef "${bin_dst}" ]; then
          rm -f "${bin_backup}"
        elif ! mv -f "${bin_backup}" "${bin_dst}"; then
          warn "could not restore ${bin_dst} from ${bin_backup}"
          failed=1
        fi
      elif [ "${expected_backup}" -eq 1 ]; then
        warn "rollback link ${bin_backup} is missing; leaving ${bin_dst} unchanged"
        failed=1
      elif ! rm -f "${bin_dst}"; then
        warn "could not remove newly installed ${bin_dst}"
        failed=1
      fi
    done <<<"${activated_paths}"
  fi

  if [ "${failed}" -eq 0 ]; then
    transaction_active=0
    return 0
  fi
  return 1
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM

  if [ "${transaction_active}" -eq 1 ] && ! rollback_installations; then
    warn "automatic rollback was incomplete; restore the .emisar-mcp.old.$$ files before retrying"
    status=1
  fi
  if [ -n "${staged_paths}" ]; then
    while IFS= read -r path; do
      [ -z "${path}" ] || rm -f -- "${path}"
    done <<<"${staged_paths}"
  fi
  if [ "${transaction_active}" -eq 0 ] && [ -n "${backup_paths}" ]; then
    while IFS= read -r path; do
      [ -z "${path}" ] || rm -f -- "${path}"
    done <<<"${backup_paths}"
  fi
  rm -rf -- "${tmp}"
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

log "downloading ${TARBALL}"
curl -fsSL -o "${tmp}/${TARBALL}" "${BASE_URL}/${TARBALL}" \
  || die "download failed: ${BASE_URL}/${TARBALL}"

log "downloading SHA256SUMS-MCP"
curl -fsSL -o "${tmp}/SHA256SUMS-MCP" "${BASE_URL}/SHA256SUMS-MCP" \
  || die "download failed: ${BASE_URL}/SHA256SUMS-MCP"

log "verifying checksum"
if command -v sha256sum >/dev/null 2>&1; then
  sha_check() { sha256sum -c -; }
  sha_value() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha_check() { shasum -a 256 -c -; }
  sha_value() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  die "neither sha256sum nor shasum found — cannot verify download"
fi

(
  cd "${tmp}"
  grep -E "  ${TARBALL}\$" SHA256SUMS-MCP | sha_check
) || die "checksum verification failed for ${TARBALL}"

log "extracting"
tar -C "${tmp}" -xzf "${tmp}/${TARBALL}"

# ---------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------

bin_src="${tmp}/${TAR_NAME}/emisar-mcp"
if [ ! -x "${bin_src}" ]; then
  die "expected ${bin_src} inside tarball but it was missing"
fi
expected_version="emisar-mcp ${VERSION_NUM}"
source_version=$("${bin_src}" --version) || die "downloaded binary did not respond to --version"
[ "${source_version}" = "${expected_version}" ] || \
  die "downloaded binary reported '${source_version}', expected '${expected_version}'"
source_sha=$(sha_value "${bin_src}")

# Preflight every target before changing any active binary. The installer may
# run as root while one target is user-writable, so it executes only bin_src in
# the root-owned temporary directory; destination files are verified by digest.
while IFS= read -r INSTALL_DIR; do
  case "${INSTALL_DIR}" in
    *$'\n'*|"") die "invalid empty or multiline install directory" ;;
  esac
  if [ ! -d "${INSTALL_DIR}" ]; then
    mkdir -p "${INSTALL_DIR}" 2>/dev/null || \
      die "could not create ${INSTALL_DIR} (re-run with sudo, or set --install-dir to a writable path)"
  fi
  if [ ! -w "${INSTALL_DIR}" ]; then
    die "${INSTALL_DIR} is not writable (re-run with sudo, or set --install-dir)"
  fi
done <<<"${install_dirs}"

while IFS= read -r INSTALL_DIR; do
  bin_dst="${INSTALL_DIR}/emisar-mcp"
  bin_staged="${INSTALL_DIR}/.emisar-mcp.new.$$"
  log "staging → ${bin_staged}"
  install -m 0755 "${bin_src}" "${bin_staged}"

  staged_paths="${staged_paths}${staged_paths:+
}${bin_staged}"
  staged_sha=$(sha_value "${bin_staged}")
  [ "${staged_sha}" = "${source_sha}" ] || \
    die "staged binary checksum changed at ${bin_staged}; no installation was activated"
done <<<"${install_dirs}"

activate_installations() {
  local INSTALL_DIR bin_dst bin_staged bin_backup installed_sha path

  # Link every old executable before changing any active path. Hard links keep
  # the exact old bytes on the destination filesystem and make rollback an
  # atomic rename too. Symlinks and special files are refused rather than
  # silently changing their semantics.
  while IFS= read -r INSTALL_DIR; do
    bin_dst="${INSTALL_DIR}/emisar-mcp"
    bin_backup="${INSTALL_DIR}/.emisar-mcp.old.$$"
    if [ -L "${bin_dst}" ] || { [ -e "${bin_dst}" ] && [ ! -f "${bin_dst}" ]; }; then
      warn "existing ${bin_dst} is not a regular file; refusing to replace it"
      return 1
    fi
    if [ -f "${bin_dst}" ]; then
      if ! ln "${bin_dst}" "${bin_backup}"; then
        warn "could not create rollback link ${bin_backup}; no installation was activated"
        return 1
      fi
      backup_paths="${backup_paths}${backup_paths:+
}${bin_backup}"
    fi
  done <<<"${install_dirs}"

  transaction_active=1
  while IFS= read -r INSTALL_DIR; do
    bin_dst="${INSTALL_DIR}/emisar-mcp"
    bin_staged="${INSTALL_DIR}/.emisar-mcp.new.$$"
    # Record the attempt first so a catchable signal after rename restores it.
    activated_paths="${activated_paths}${activated_paths:+
}${bin_dst}"
    if ! mv -f "${bin_staged}" "${bin_dst}"; then
      warn "could not atomically activate ${bin_dst}"
      return 1
    fi
    installed_sha=$(sha_value "${bin_dst}")
    if [ "${installed_sha}" != "${source_sha}" ]; then
      warn "installed binary checksum changed at ${bin_dst}"
      return 1
    fi
  done <<<"${install_dirs}"

  # Commit only after the complete set still matches the verified source.
  while IFS= read -r bin_dst; do
    installed_sha=$(sha_value "${bin_dst}")
    if [ "${installed_sha}" != "${source_sha}" ]; then
      warn "installed binary checksum changed at ${bin_dst}"
      return 1
    fi
  done <<<"${activated_paths}"

  transaction_active=0
  installed_paths="${activated_paths}"
  staged_paths=""
  if [ -n "${backup_paths}" ]; then
    while IFS= read -r path; do
      if [ -n "${path}" ] && ! rm -f -- "${path}"; then
        warn "could not remove rollback link ${path}"
      fi
    done <<<"${backup_paths}"
  fi
  backup_paths=""
}

activate_installations || die "installation failed; rolling back previous installations"

# ---------------------------------------------------------------------
# Offer to add emisar to local LLM clients
# ---------------------------------------------------------------------
# Interactive-only: each client is offered individually and a client that
# already carries an emisar entry is left untouched (so the portal's
# upgrade one-liner stays quiet). The API keys come from a device-grant
# approval (RFC 8628 shape): the operator approves the printed link in
# the portal and the poll delivers the keys straight into the configs —
# no secret ever touches argv, env, history, or sudo's syslog.
# The file shapes mirror the portal's /app/agents snippets exactly.

CONFIGURED_CLIENTS=""
clients_phase_ran=0
CLIENTS_FOUND=0
SCANNED=""
CONSENTED=""
DEVICE_CODE=""
DEVICE_USER_CODE=""
DEVICE_VERIFY_URI=""
DEVICE_INTERVAL=5
DEVICE_EXPIRES_IN=900

tty_available() {
  [ -t 0 ] && return 0
  if { exec 3</dev/tty; } 2>/dev/null; then
    exec 3<&-
    return 0
  fi
  return 1
}

# Same TTY-fallback dance as confirm(), minus the ASSUME_YES bypass:
# these are per-client consent questions, not the install confirmation.
ask_tty() {
  local reply=""
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

# Plain human-facing output for the interactive phases — no log prefix.
# (Named `out`, and never `say` — macOS ships a text-to-speech /usr/bin/say
# that would win if the function definition were ever missed.)
out() {
  printf '%s\n' "$*"
}

# Bold section line when stdout is a terminal; plain otherwise.
hdr() {
  if [ -t 1 ]; then
    printf '\033[1m%s\033[0m\n' "$*"
  else
    printf '%s\n' "$*"
  fi
}

# The success moment — bold green on a terminal, plain otherwise.
ok() {
  if [ -t 1 ]; then
    printf '\033[1;32m%s\033[0m\n' "$*"
  else
    printf '%s\n' "$*"
  fi
}

# Secondary/reference lines (the verify/uninstall footer) — faint on a
# terminal, plain otherwise.
dim() {
  if [ -t 1 ]; then
    printf '\033[2m%s\033[0m\n' "$*"
  else
    printf '%s\n' "$*"
  fi
}

# One aligned client row; `style` is an SGR code for the status column
# ("2" faint, "1;32" green) or empty for plain.
client_row() {
  local label="$1" style="$2" text="$3"
  if [ -t 1 ] && [ -n "${style}" ]; then
    printf '  %-15s \033[%sm%s\033[0m\n' "${label}" "${style}" "${text}"
  else
    printf '  %-15s %s\n' "${label}" "${text}"
  fi
}

# Best-effort: open the approval URL in the invoking user's browser (never
# root's). Failure is fine — the link is already printed.
open_browser() {
  local url="$1" opener=""
  case "${OS}" in
    darwin) opener="open" ;;
    linux) opener="xdg-open" ;;
  esac
  [ -n "${opener}" ] || return 1
  command -v "${opener}" >/dev/null 2>&1 || return 1
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    sudo -u "${SUDO_USER}" "${opener}" "${url}" >/dev/null 2>&1
  else
    "${opener}" "${url}" >/dev/null 2>&1
  fi
}

# `"emisar"` with both quotes is precise for JSON configs: escaped text
# inside JSON strings renders as `\"emisar\"` bytes, so prose in a big
# stateful file (~/.claude.json) cannot false-positive.
json_config_has_emisar() {
  [ -e "$1" ] && grep -Fq '"emisar"' "$1" 2>/dev/null
}

toml_config_has_emisar() {
  [ -e "$1" ] && grep -Fq 'mcp_servers.emisar' "$1" 2>/dev/null
}

yaml_config_has_emisar() {
  [ -e "$1" ] && grep -Eq '^[[:space:]]+emisar:' "$1" 2>/dev/null
}

file_has_content() {
  [ -e "$1" ] && grep -q '[^[:space:]]' "$1" 2>/dev/null
}

# printf-assembled (not a heredoc) so no line is a bare `}` — the CI
# smoke harness extracts functions by their closing column-0 brace.
write_fresh_json_config() {
  local file="$1" bin="$2" url="$3" key="$4" client="$5"
  local tmp_out="${file}.emisar-new.$$"
  {
    printf '{\n'
    printf '  "mcpServers": {\n'
    printf '    "emisar": {\n'
    printf '      "command": "%s",\n' "${bin}"
    printf '      "env": {\n'
    printf '        "EMISAR_URL": "%s",\n' "${url}"
    printf '        "EMISAR_API_KEY": "%s",\n' "${key}"
    printf '        "EMISAR_CLIENT": "%s"\n' "${client}"
    printf '      }\n'
    printf '    }\n'
    printf '  }\n'
    printf '}\n'
  } >"${tmp_out}" || { rm -f "${tmp_out}"; return 1; }
  chmod 0600 "${tmp_out}" && mv "${tmp_out}" "${file}"
}

# Merge into an existing JSON config, preserving every other key, writing
# the client's exact upstream schema (`shape`). python3 first; jq covers only
# the standard mcpServers shape; no tool → fail so the caller prints the
# manual path.
merge_json_config() {
  local file="$1" bin="$2" url="$3" key="$4" client="$5" shape="${6:-std}"
  local status=0
  if command -v python3 >/dev/null 2>&1; then
    MCP_FILE="${file}" MCP_BIN="${bin}" MCP_URL="${url}" MCP_KEY="${key}" \
      MCP_CLIENT="${client}" MCP_SHAPE="${shape}" python3 - 2>/dev/null <<'PY' || status=1
import json, os, tempfile

def container(data, *keys):
    for key in keys:
        data = data.setdefault(key, {})
        if not isinstance(data, dict):
            raise SystemExit("existing config key is not an object: " + key)
    return data

def main():
    path = os.environ["MCP_FILE"]
    with open(path) as handle:
        raw = handle.read()
    data = json.loads(raw) if raw.strip() else {}
    if not isinstance(data, dict):
        raise SystemExit("top-level JSON is not an object")
    bin_path = os.environ["MCP_BIN"]
    entry_env = {
        "EMISAR_URL": os.environ["MCP_URL"],
        "EMISAR_API_KEY": os.environ["MCP_KEY"],
        "EMISAR_CLIENT": os.environ["MCP_CLIENT"],
    }
    shape = os.environ["MCP_SHAPE"]
    if shape == "std":
        container(data, "mcpServers")["emisar"] = {"command": bin_path, "env": entry_env}
    elif shape == "openclaw":
        container(data, "mcp", "servers")["emisar"] = {"command": bin_path, "env": entry_env}
    elif shape == "opencode":
        container(data, "mcp")["emisar"] = {
            "type": "local",
            "command": [bin_path],
            "enabled": True,
            "environment": entry_env,
        }
    elif shape == "copilot":
        container(data, "mcpServers")["emisar"] = {
            "type": "local",
            "command": bin_path,
            "args": [],
            "env": entry_env,
            "tools": ["*"],
        }
    elif shape == "zed":
        container(data, "context_servers")["emisar"] = {
            "source": "custom",
            "command": bin_path,
            "args": [],
            "env": entry_env,
        }
    else:
        raise SystemExit("unknown shape: " + shape)
    fd, tmp = tempfile.mkstemp(prefix=".emisar-mcp.", dir=os.path.dirname(path) or ".")
    with os.fdopen(fd, "w") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.replace(tmp, path)

main()
PY
    return "${status}"
  fi
  [ "${shape}" = "std" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    local tmp_out="${file}.emisar-new.$$"
    jq --arg cmd "${bin}" --arg url "${url}" --arg key "${key}" --arg client "${client}" \
      '.mcpServers.emisar = {command: $cmd, env: {EMISAR_URL: $url, EMISAR_API_KEY: $key, EMISAR_CLIENT: $client}}' \
      "${file}" >"${tmp_out}" 2>/dev/null || status=1
    if [ "${status}" -eq 0 ]; then
      chmod 0600 "${tmp_out}" && mv "${tmp_out}" "${file}" && return 0
    fi
    rm -f "${tmp_out}"
    return 1
  fi
  return 1
}

# Codex config is TOML; appending a new table to a complete document is
# always valid, and the caller already checked the table doesn't exist.
append_codex_toml() {
  local file="$1" bin="$2" url="$3" key="$4"
  local tmp_out="${file}.emisar-new.$$"
  if [ -e "${file}" ]; then
    cp -p "${file}" "${tmp_out}" || return 1
  else
    : >"${tmp_out}" || return 1
  fi
  if file_has_content "${tmp_out}"; then
    printf '\n' >>"${tmp_out}"
  fi
  {
    printf '[mcp_servers.emisar]\n'
    printf 'command = "%s"\n' "${bin}"
    printf 'env = { EMISAR_URL = "%s", EMISAR_API_KEY = "%s", EMISAR_CLIENT = "codex" }\n' \
      "${url}" "${key}"
  } >>"${tmp_out}" || { rm -f "${tmp_out}"; return 1; }
  chmod 0600 "${tmp_out}" && mv "${tmp_out}" "${file}"
}

# Hermes/Goose configs are YAML. A safe bash append needs the top-level key
# absent — merging INTO existing YAML risks duplicate keys, so that case
# falls back to the portal snippet. Field names are each client's own
# schema (hermes: command/env; goose: cmd/envs/type/timeout).
append_yaml_config() {
  local kind="$1" file="$2" bin="$3" url="$4" key="$5" client="$6"
  local top tmp_out
  case "${kind}" in
    hermes) top="mcp_servers" ;;
    goose) top="extensions" ;;
    *) return 1 ;;
  esac
  if [ -e "${file}" ] && grep -Eq "^${top}:" "${file}" 2>/dev/null; then
    return 1
  fi
  tmp_out="${file}.emisar-new.$$"
  if [ -e "${file}" ]; then
    cp -p "${file}" "${tmp_out}" || return 1
  else
    : >"${tmp_out}" || return 1
  fi
  if file_has_content "${tmp_out}"; then
    printf '\n' >>"${tmp_out}"
  fi
  {
    if [ "${kind}" = "hermes" ]; then
      printf 'mcp_servers:\n'
      printf '  emisar:\n'
      printf '    command: %s\n' "${bin}"
      printf '    env:\n'
      printf '      EMISAR_URL: "%s"\n' "${url}"
      printf '      EMISAR_API_KEY: "%s"\n' "${key}"
      printf '      EMISAR_CLIENT: %s\n' "${client}"
    else
      printf 'extensions:\n'
      printf '  emisar:\n'
      printf '    name: emisar\n'
      printf '    cmd: %s\n' "${bin}"
      printf '    args: []\n'
      printf '    enabled: true\n'
      printf '    envs:\n'
      printf '      EMISAR_URL: "%s"\n' "${url}"
      printf '      EMISAR_API_KEY: "%s"\n' "${key}"
      printf '      EMISAR_CLIENT: %s\n' "${client}"
      printf '    type: stdio\n'
      printf '    timeout: 300\n'
    fi
  } >>"${tmp_out}" || { rm -f "${tmp_out}"; return 1; }
  chmod 0600 "${tmp_out}" && mv "${tmp_out}" "${file}"
}

# A sudo run writes as root into the invoking user's home — hand the
# file back so the client (running as the user) can read it.
own_config_file() {
  local file="$1" group
  [ "$(id -u)" -eq 0 ] || return 0
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    group="$(id -g "${SUDO_USER}" 2>/dev/null)" || return 0
    chown "${SUDO_USER}:${group}" "${file}" 2>/dev/null || true
  fi
}

install_client_config() {
  local kind="$1" config_file="$2" key="$3" client_id="$4"
  local config_dir
  config_dir=$(dirname "${config_file}")
  if [ ! -d "${config_dir}" ]; then
    mkdir -p "${config_dir}" || return 1
    own_config_file "${config_dir}"
  fi
  case "${kind}" in
    json)
      if file_has_content "${config_file}"; then
        cp -p "${config_file}" "${config_file}.emisar-bak" || return 1
        merge_json_config "${config_file}" "${first_bin}" "${EMISAR_URL}" "${key}" "${client_id}"
      else
        write_fresh_json_config "${config_file}" "${first_bin}" "${EMISAR_URL}" "${key}" "${client_id}"
      fi
      ;;
    opencode|openclaw|copilot|zed)
      # Non-standard JSON schemas need the real merge — python3 only.
      command -v python3 >/dev/null 2>&1 || return 1
      if file_has_content "${config_file}"; then
        cp -p "${config_file}" "${config_file}.emisar-bak" || return 1
      else
        printf '{}\n' >"${config_file}" || return 1
      fi
      merge_json_config "${config_file}" "${first_bin}" "${EMISAR_URL}" "${key}" "${client_id}" "${kind}"
      ;;
    toml)
      if file_has_content "${config_file}"; then
        cp -p "${config_file}" "${config_file}.emisar-bak" || return 1
      fi
      append_codex_toml "${config_file}" "${first_bin}" "${EMISAR_URL}" "${key}"
      ;;
    hermes|goose)
      if file_has_content "${config_file}"; then
        cp -p "${config_file}" "${config_file}.emisar-bak" || return 1
      fi
      append_yaml_config "${kind}" "${config_file}" "${first_bin}" "${EMISAR_URL}" "${key}" "${client_id}"
      ;;
    *) return 1 ;;
  esac
}

# JSON response field readers — the same python3-then-jq ladder as config
# merging; a machine with neither falls back to the portal's manual snippets.
json_string_field() {
  local file="$1" key="$2"
  local status=0
  if command -v python3 >/dev/null 2>&1; then
    MCP_JSON_FILE="${file}" MCP_JSON_KEY="${key}" python3 - 2>/dev/null <<'PY' || status=1
import json, os

def main():
    with open(os.environ["MCP_JSON_FILE"]) as handle:
        data = json.load(handle)
    value = data[os.environ["MCP_JSON_KEY"]]
    if isinstance(value, (dict, list)):
        raise SystemExit(1)
    print(value)

main()
PY
    return "${status}"
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -er --arg key "${key}" '.[$key] // empty | tostring' "${file}" 2>/dev/null
    return "$?"
  fi
  return 1
}

json_client_key() {
  local file="$1" client="$2"
  local status=0
  if command -v python3 >/dev/null 2>&1; then
    MCP_JSON_FILE="${file}" MCP_JSON_CLIENT="${client}" python3 - 2>/dev/null <<'PY' || status=1
import json, os

def main():
    with open(os.environ["MCP_JSON_FILE"]) as handle:
        data = json.load(handle)
    value = data["client_keys"][os.environ["MCP_JSON_CLIENT"]]
    if not isinstance(value, str):
        raise SystemExit(1)
    print(value)

main()
PY
    return "${status}"
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -er --arg client "${client}" '.client_keys[$client] // empty' "${file}" 2>/dev/null
    return "$?"
  fi
  return 1
}

# Opens the device grant for the consented clients. Sets DEVICE_* from the
# response; any failure means "use the portal's manual snippets instead".
request_device_grant() {
  local ids="$1" id json_ids="" body status
  for id in ${ids}; do
    json_ids="${json_ids}${json_ids:+,}\"${id}\""
  done
  body="{\"requested_clients\":[${json_ids}]}"
  status=$(curl -sS -m 15 -H 'Content-Type: application/json' -d "${body}" \
    -o "${DEVICE_RESP}" -w '%{http_code}' \
    "${EMISAR_URL}/api/mcp/device_authorization") || return 1
  [ "${status}" = "200" ] || return 1
  DEVICE_CODE=$(json_string_field "${DEVICE_RESP}" device_code) || return 1
  DEVICE_USER_CODE=$(json_string_field "${DEVICE_RESP}" user_code) || return 1
  DEVICE_VERIFY_URI=$(json_string_field "${DEVICE_RESP}" verification_uri_complete) || return 1
  DEVICE_INTERVAL=$(json_string_field "${DEVICE_RESP}" interval) || DEVICE_INTERVAL=5
  DEVICE_EXPIRES_IN=$(json_string_field "${DEVICE_RESP}" expires_in) || DEVICE_EXPIRES_IN=900
}

# Polls the token endpoint until approval (0; TOKEN_RESP holds the keys),
# denial, or expiry. Network blips and rate limits just keep polling.
await_device_approval() {
  local deadline now status error
  deadline=$(($(date +%s) + DEVICE_EXPIRES_IN))
  out ""
  hdr "Approve this machine in your browser"
  out ""
  out "  ${DEVICE_VERIFY_URI}"
  out ""
  if open_browser "${DEVICE_VERIFY_URI}"; then
    out "Opened your browser — approve there, or use the link above."
  else
    out "Or enter code ${DEVICE_USER_CODE} by hand at ${EMISAR_URL}/activate."
  fi
  out "Waiting for approval (Ctrl-C skips client setup)…"
  while :; do
    now=$(date +%s)
    if [ "${now}" -ge "${deadline}" ]; then
      warn "approval code expired — re-run the installer to try again"
      return 1
    fi
    sleep "${DEVICE_INTERVAL}"
    status=$(curl -sS -m 15 -H 'Content-Type: application/json' \
      -d "{\"device_code\":\"${DEVICE_CODE}\"}" \
      -o "${TOKEN_RESP}" -w '%{http_code}' \
      "${EMISAR_URL}/api/mcp/device_token") || continue
    if [ "${status}" = "200" ]; then
      out ""
      out ""
      ok "Approved."
      return 0
    fi
    error=$(json_string_field "${TOKEN_RESP}" error) || error=""
    case "${error}" in
      access_denied)
        warn "the request was denied in the portal — no clients configured"
        return 1
        ;;
      expired_token)
        warn "approval code expired — re-run the installer to try again"
        return 1
        ;;
      *) : ;;
    esac
  done
}

# Detection for one client: records `label|id|kind|file|state`, where state
# is "connected" (already carries emisar — left untouched, so the portal's
# upgrade one-liner stays quiet) or "candidate".
scan_client() {
  local label="$1" client_id="$2" kind="$3" config_file="$4" state="candidate"
  case "${kind}" in
    toml)
      toml_config_has_emisar "${config_file}" && state="connected"
      ;;
    hermes|goose)
      yaml_config_has_emisar "${config_file}" && state="connected"
      ;;
    *)
      json_config_has_emisar "${config_file}" && state="connected"
      ;;
  esac
  CLIENTS_FOUND=$((CLIENTS_FOUND + 1))
  SCANNED="${SCANNED}${SCANNED:+
}${label}|${client_id}|${kind}|${config_file}|${state}"
}

configure_llm_clients() {
  local user_home="$1" desktop_dir ids="" label client_id kind config_file state key
  CONFIGURED_CLIENTS=""
  CLIENTS_FOUND=0
  SCANNED=""
  CONSENTED=""
  [ "${ASSUME_YES}" = "1" ] && return 0
  tty_available || return 0
  clients_phase_ran=1
  DEVICE_RESP="${DEVICE_RESP:-${tmp}/device-authorization.json}"
  TOKEN_RESP="${TOKEN_RESP:-${tmp}/device-token.json}"

  if [ -e "${user_home}/.claude.json" ] || [ -d "${user_home}/.claude" ]; then
    scan_client "Claude Code" claude-code json "${user_home}/.claude.json"
  fi
  desktop_dir="${user_home}/Library/Application Support/Claude"
  [ "${OS}" = "linux" ] && desktop_dir="${user_home}/.config/Claude"
  if [ -d "${desktop_dir}" ]; then
    scan_client "Claude Desktop" claude-desktop json "${desktop_dir}/claude_desktop_config.json"
  fi
  if [ -d "${user_home}/.cursor" ]; then
    scan_client "Cursor" cursor json "${user_home}/.cursor/mcp.json"
  fi
  if [ -d "${user_home}/.gemini" ]; then
    scan_client "Gemini CLI" gemini json "${user_home}/.gemini/settings.json"
  fi
  if [ -d "${user_home}/.codex" ]; then
    scan_client "Codex CLI" codex toml "${user_home}/.codex/config.toml"
  fi
  if [ -d "${user_home}/.openclaw" ]; then
    scan_client "OpenClaw" openclaw openclaw "${user_home}/.openclaw/openclaw.json"
  fi
  if [ -d "${user_home}/.config/opencode" ]; then
    scan_client "OpenCode" opencode opencode "${user_home}/.config/opencode/opencode.json"
  fi
  if [ -d "${user_home}/.codeium/windsurf" ]; then
    scan_client "Windsurf" windsurf json "${user_home}/.codeium/windsurf/mcp_config.json"
  fi
  if [ -d "${user_home}/.pi" ]; then
    scan_client "Pi" pi json "${user_home}/.pi/agent/mcp.json"
  fi
  if [ -d "${user_home}/.copilot" ]; then
    scan_client "Copilot CLI" copilot-cli copilot "${user_home}/.copilot/mcp-config.json"
  fi
  if [ -d "${user_home}/.config/zed" ]; then
    scan_client "Zed" zed zed "${user_home}/.config/zed/settings.json"
  fi
  if [ -d "${user_home}/.hermes" ]; then
    scan_client "Hermes" hermes hermes "${user_home}/.hermes/config.yaml"
  fi
  if [ -d "${user_home}/.config/goose" ]; then
    scan_client "Goose" goose goose "${user_home}/.config/goose/config.yaml"
  fi

  if [ "${CLIENTS_FOUND}" -eq 0 ]; then
    out ""
    out "No supported LLM clients found on this machine — connect one from"
    out "${EMISAR_URL}/app/agents whenever you're ready."
    return 0
  fi

  # The scan as one aligned table, then the questions — never interleaved.
  out ""
  hdr "Connect your LLM clients"
  out ""
  while IFS='|' read -r label client_id kind config_file state; do
    [ -n "${client_id}" ] || continue
    if [ "${state}" = "connected" ]; then
      client_row "${label}" 2 "already connected"
    else
      client_row "${label}" 33 "not connected"
    fi
  done <<<"${SCANNED}"
  out ""

  while IFS='|' read -r label client_id kind config_file state; do
    [ "${state}" = "candidate" ] || continue
    if ask_tty "Add emisar to ${label}?"; then
      CONSENTED="${CONSENTED}${CONSENTED:+
}${label}|${client_id}|${kind}|${config_file}"
    fi
  done <<<"${SCANNED}"
  [ -n "${CONSENTED}" ] || return 0

  if ! command -v python3 >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1; then
    warn "python3 or jq is needed to finish setup here — use the manual snippets at ${EMISAR_URL}/app/agents/connect"
    return 0
  fi

  while IFS='|' read -r label client_id kind config_file; do
    [ -n "${client_id}" ] && ids="${ids}${ids:+ }${client_id}"
  done <<<"${CONSENTED}"

  if ! request_device_grant "${ids}"; then
    warn "could not start connection approval against ${EMISAR_URL} — use the manual snippets at ${EMISAR_URL}/app/agents/connect"
    return 0
  fi

  await_device_approval || return 0

  out ""
  while IFS='|' read -r label client_id kind config_file; do
    [ -n "${client_id}" ] || continue
    if ! key=$(json_client_key "${TOKEN_RESP}" "${client_id}"); then
      warn "${label}: no key was delivered — use its snippet at ${EMISAR_URL}/app/agents/connect"
      continue
    fi
    if install_client_config "${kind}" "${config_file}" "${key}" "${client_id}"; then
      own_config_file "${config_file}"
      CONFIGURED_CLIENTS="${CONFIGURED_CLIENTS}${CONFIGURED_CLIENTS:+
}${label}: ${config_file}"
      client_row "${label}" "1;32" "connected → ${config_file}"
    else
      warn "${label}: could not update ${config_file} — paste its snippet from ${EMISAR_URL}/app/agents/connect instead"
    fi
  done <<<"${CONSENTED}"
}

# ---------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------

out ""
hdr "${expected_version} installed"
while IFS= read -r bin_dst; do
  out "  ${bin_dst}"
done <<<"${installed_paths}"

first_bin=${installed_paths%%$'\n'*}

configure_llm_clients "$(invoking_user_home)" || \
  warn "client setup did not complete — per-client snippets: ${EMISAR_URL}/app/agents/connect"

# After an interactive run the aligned client lines above have already said
# everything (connected / already connected / declined / none found) — no
# trailing how-to block. Only a run that never offered setup (--yes or no
# TTY) still owes the one pointer.
if [ -n "${CONFIGURED_CLIENTS}" ]; then
  out ""
  out "Restart each connected client to pick up emisar."
  out "Manage agents and their keys: ${EMISAR_URL}/app/agents"
elif [ "${clients_phase_ran}" = "0" ]; then
  out ""
  out "Connect an LLM client: ${EMISAR_URL}/app/agents/connect"
fi

out ""
dim "Verify install:"
dim "  ${first_bin} --help"
out ""
dim "Uninstall:"
while IFS= read -r path; do
  dim "  rm ${path}"
done <<<"${installed_paths}"

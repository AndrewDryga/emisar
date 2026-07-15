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
# The script is idempotent. It does NOT register a service or write
# config — the bridge is configured per-client via env vars in the
# launcher's JSON/TOML config, which the portal generates for you on
# the /app/agents page.

set -Eeuo pipefail

REPO="${EMISAR_REPO:-andrewdryga/emisar}"
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
  --yes               Skip the confirmation prompt.
  --help              This message.

Env vars accepted: VERSION, INSTALL_DIR, EMISAR_REPO, EMISAR_GITHUB_TOKEN,
ASSUME_YES.
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

tmp="$(mktemp -d -t emisar-mcp-install.XXXXXX)"
staged_paths=""
cleanup() {
  if [ -n "${staged_paths}" ]; then
    while IFS= read -r path; do
      [ -z "${path}" ] || rm -f -- "${path}"
    done <<<"${staged_paths}"
  fi
  rm -rf -- "${tmp}"
}
trap cleanup EXIT

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

installed_paths=""
while IFS= read -r INSTALL_DIR; do
  bin_dst="${INSTALL_DIR}/emisar-mcp"
  bin_staged="${INSTALL_DIR}/.emisar-mcp.new.$$"
  # Staging on the destination filesystem makes activation one atomic rename.
  if ! mv -f "${bin_staged}" "${bin_dst}"; then
    die "could not atomically activate ${bin_dst}; its previous installation is unchanged"
  fi
  installed_paths="${installed_paths}${installed_paths:+
}${bin_dst}"
done <<<"${install_dirs}"
staged_paths=""

# ---------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------

log "installed:"
while IFS= read -r bin_dst; do
  installed_sha=$(sha_value "${bin_dst}")
  [ "${installed_sha}" = "${source_sha}" ] || \
    die "installed binary checksum changed at ${bin_dst}"
  log "${bin_dst}: ${expected_version}"
done <<<"${installed_paths}"

first_bin=${installed_paths%%$'\n'*}

cat <<NEXT

Next steps:
  - Open https://emisar.dev/app/agents in your browser.
  - Pick your LLM client; the page shows you the per-client config
    snippet (path + env vars) to paste into the client launcher.

Verify install:
  ${first_bin} --help

Uninstall:
$(while IFS= read -r path; do printf '  rm %s\n' "${path}"; done <<<"${installed_paths}")
NEXT

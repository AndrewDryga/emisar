#!/usr/bin/env bash
# install-mcp.sh — Drop the emisar-mcp stdio bridge into /usr/local/bin.
#
# The bridge is a single self-contained Go binary that an MCP-aware
# client (Claude Desktop, Claude Code, Cursor, Gemini CLI, Codex CLI,
# …) launches as a child process and talks to over stdin/stdout. It
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

set -euo pipefail

REPO="${EMISAR_REPO:-andrewdryga/emisar}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VERSION="${VERSION:-}"     # empty → latest mcp-v* tag

usage() {
  cat <<'USAGE'
emisar-mcp installer

Usage: install-mcp.sh [--version TAG] [--install-dir DIR] [--yes]

Flags:
  --version TAG       Install a specific MCP release. Accepts
                      `mcp-vX.Y.Z`, `vX.Y.Z`, or bare `X.Y.Z`
                      (auto-prefixed with `mcp-v`). Default: latest.
  --install-dir DIR   Where to place the `emisar-mcp` binary
                      (default /usr/local/bin).
  --yes               Skip the confirmation prompt.
  --help              This message.

Env vars accepted: VERSION, INSTALL_DIR, EMISAR_REPO, ASSUME_YES.
USAGE
}

ASSUME_YES="${ASSUME_YES:-0}"

normalize_version() {
  case "$1" in
    mcp-v*) printf '%s\n' "$1";;
    v*)     printf 'mcp-%s\n' "$1";;
    *)      printf 'mcp-v%s\n' "$1";;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)     VERSION="$(normalize_version "$2")"; shift 2;;
    --install-dir) INSTALL_DIR="$2"; shift 2;;
    --yes|-y)      ASSUME_YES=1; shift;;
    --help|-h)     usage; exit 0;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2;;
  esac
done

log()  { printf '\033[1;34m[install-mcp]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install-mcp]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install-mcp]\033[0m %s\n' "$*" >&2; exit 1; }

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

log "install target: ${OS}/${ARCH} → ${INSTALL_DIR}/emisar-mcp"

# ---------------------------------------------------------------------
# Resolve version
# ---------------------------------------------------------------------

if [ -z "${VERSION}" ]; then
  log "querying latest mcp-v* release"
  VERSION=$(
    curl -fsSL -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/${REPO}/releases?per_page=30" \
      | grep -oE '"tag_name":[[:space:]]*"mcp-v[^"]+"' \
      | head -1 \
      | sed -E 's/.*"(mcp-v[^"]+)".*/\1/'
  ) || die "could not query GitHub releases API"
  [ -n "${VERSION}" ] || die "no mcp-v* release found yet"
  log "latest release: ${VERSION}"
else
  log "pinned release: ${VERSION}"
fi

VERSION_NUM="${VERSION#mcp-v}"
TAR_NAME="emisar-mcp-${VERSION_NUM}-${OS}-${ARCH}"
TARBALL="${TAR_NAME}.tar.gz"
BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"

if ! confirm "install emisar-mcp ${VERSION} → ${INSTALL_DIR}/emisar-mcp?"; then
  die "aborted by user"
fi

# ---------------------------------------------------------------------
# Download + verify
# ---------------------------------------------------------------------

tmp="$(mktemp -d -t emisar-mcp-install.XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

log "downloading ${TARBALL}"
curl -fsSL -o "${tmp}/${TARBALL}" "${BASE_URL}/${TARBALL}" \
  || die "download failed: ${BASE_URL}/${TARBALL}"

log "downloading SHA256SUMS-MCP"
curl -fsSL -o "${tmp}/SHA256SUMS-MCP" "${BASE_URL}/SHA256SUMS-MCP" \
  || die "download failed: ${BASE_URL}/SHA256SUMS-MCP"

log "verifying checksum"
if command -v sha256sum >/dev/null 2>&1; then
  sha_check() { sha256sum -c -; }
elif command -v shasum >/dev/null 2>&1; then
  sha_check() { shasum -a 256 -c -; }
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

if [ ! -d "${INSTALL_DIR}" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    mkdir -p "${INSTALL_DIR}"
  else
    die "${INSTALL_DIR} does not exist (re-run with sudo, or set --install-dir to a writable path)"
  fi
fi

if [ ! -w "${INSTALL_DIR}" ]; then
  die "${INSTALL_DIR} is not writable (re-run with sudo, or set --install-dir)"
fi

bin_src="${tmp}/${TAR_NAME}/emisar-mcp"
bin_dst="${INSTALL_DIR}/emisar-mcp"

if [ ! -x "${bin_src}" ]; then
  die "expected ${bin_src} inside tarball but it was missing"
fi

log "installing → ${bin_dst}"
install -m 0755 "${bin_src}" "${bin_dst}"

# ---------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------

log "installed:"
"${bin_dst}" --version || true

cat <<NEXT

Next steps:
  - Open https://app.emisar.dev/app/agents in your browser.
  - Pick your LLM client; the page shows you the per-client config
    snippet (path + env vars) to paste into the client launcher.

Verify install:
  ${bin_dst} --help

Uninstall:
  rm ${bin_dst}
NEXT

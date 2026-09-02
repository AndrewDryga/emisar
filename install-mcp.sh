#!/usr/bin/env bash
# install-mcp.sh — Install or upgrade the emisar-mcp stdio bridge.
#
# The bridge is a single self-contained Go binary that an MCP-aware
# client (Claude Desktop, Claude Code, Cursor, VS Code, Gemini CLI, Codex CLI,
# Grok, …) launches as a child process and talks to over stdin/stdout. It
# proxies JSON-RPC frames to the emisar control plane's
# `/api/mcp/rpc` endpoint and forwards responses back.
#
# Usage:
#
#   curl -fsSL https://emisar.dev/install-mcp.sh | sudo bash
#
#   # Pin a version:
#   curl -fsSL https://.../install-mcp.sh | sudo bash -s -- --version mcp-vX.Y.Z
#
#   # Install to a per-user location (no sudo):
#   curl -fsSL https://.../install-mcp.sh | INSTALL_DIR=$HOME/.local/bin bash
#
#   # Uninstall — binary, client entries, CLI credential, and rotation state:
#   curl -fsSL https://.../install-mcp.sh | sudo bash -s -- --uninstall
#
# The script is idempotent. It does not register a service. After
# installing, an interactive run authenticates the direct CLI and scans for
# local LLM clients (Claude
# Code, Claude Desktop, Cursor, VS Code, Gemini CLI, Codex CLI, OpenClaw,
# OpenCode, Windsurf, Pi, Copilot CLI, Zed, Hermes, Goose, Grok CLI) and offers
# to add emisar to each — asking per client; a non-interactive or --yes
# run skips that entirely. For the clients whose "stop asking" setting can be
# scoped to the emisar server alone (Claude Code, Gemini CLI, Codex CLI, Grok
# CLI), it then offers once to silence that client's own per-tool prompt for
# emisar; declining is the default and no global approval setting is ever
# touched. The API keys come from one browser approval
# (the script prints an approval link; no key is ever typed or copied)
# and land in owner-only CLI state, client configs, or VS Code's private
# environment file, pointed at EMISAR_URL.
# Manual per-client snippets stay available on the portal's
# /app/agents page.

set -Eeuo pipefail

# GitHub owner/repo slugs are case-insensitive, so an operator may paste the
# display casing (AndrewDryga/emisar). Lowercase it so the OFFICIAL_REPO gate
# runs provenance instead of skipping it. The signer SAN (ATTESTATION_WORKFLOW)
# keeps its exact casing — a separate constant, not derived from REPO.
REPO="$(printf '%s' "${EMISAR_REPO:-andrewdryga/emisar}" | tr '[:upper:]' '[:lower:]')"
OFFICIAL_REPO="andrewdryga/emisar"
RELEASE_BASE_URL="https://emisar.dev/releases/mcp"
# Matched literally against the signing certificate's SubjectAlternativeName,
# which carries GitHub's canonical owner casing (AndrewDryga) — NOT the
# lowercase spelling REPO uses. Deriving this from REPO reads as obviously
# correct and fails every verification, so it is written out. A fork gets no
# default: pinning ours would fail their install, so they set their own or the
# checksum stands alone. The official default depends on the resolved release
# tag and is selected below.
ATTESTATION_WORKFLOW="${EMISAR_ATTESTATION_WORKFLOW:-}"
ATTESTATION_SIGNER_DIGEST=""
ATTESTATION_SOURCE_REF=""
ATTESTATION_DENY_SELF_HOSTED=0
# The portal this bridge talks to. A self-hosted or dev portal's install
# command overrides it (the client configs written below carry it).
EMISAR_URL="${EMISAR_URL:-https://emisar.dev}"
EMISAR_URL="${EMISAR_URL%/}"
# Validated where it is READ, not where it is written: this value and the keys
# the portal delivers both land inside JSON, TOML and YAML string literals. A
# value carrying a quote or a newline does not corrupt those files — it ADDS to
# them, and every one of those formats can express a second MCP server with its
# own `command`, which the client runs on next start. So a hostile EMISAR_URL,
# or a compromised portal's response, would reach arbitrary code on the
# operator's workstation through a config file. One charset check beats three
# per-format escapers.
safe_config_value() {
  case "$1" in
    "") return 1 ;;
    *[!A-Za-z0-9._:/@+-]*) return 1 ;;
  esac
  return 0
}
INSTALL_DIR="${INSTALL_DIR:-}"
INSTALL_DIR_EXPLICIT=0
[ -n "${INSTALL_DIR}" ] && INSTALL_DIR_EXPLICIT=1
VERSION="${VERSION:-}"     # empty → latest mcp-v* tag
MODE="install"             # install|uninstall

usage() {
  cat <<'USAGE'
emisar-mcp installer

Usage: install-mcp.sh [--version TAG] [--install-dir DIR] [--uninstall] [--yes]

Flags:
  --version TAG       Install a specific MCP release. Accepts
                      `mcp-vX.Y.Z`, `vX.Y.Z`, or bare `X.Y.Z`
                      (auto-prefixed with `mcp-v`). Default: latest.
  --install-dir DIR   Where to place the `emisar-mcp` binary. By default,
                      existing user-local and system installs are upgraded;
                      a fresh install uses /usr/local/bin.
  --uninstall         Remove the emisar-mcp binary (from the conventional
                      locations, or --install-dir), the emisar entry and
                      .emisar-bak backups in detected LLM client configs,
                      every stored direct-CLI account, and bridge rotation
                      state.
                      Connected keys stay valid until revoked on the portal's
                      /app/agents; unused installer keys stay hidden and expire
                      after 30 days.
  --yes               Skip the confirmation prompt and interactive CLI/client
                      authentication.
  --help              This message.

Env vars accepted: VERSION, INSTALL_DIR, EMISAR_REPO, EMISAR_GITHUB_TOKEN,
ASSUME_YES, EMISAR_URL (the portal the bridge talks to; default
https://emisar.dev — a self-hosted portal's install command sets it).
USAGE
}

# A yes/no environment variable accepts the spellings people actually type.
# These used to require the literal "1", so `ASSUME_YES=true curl | sudo bash`
# silently stayed interactive, hit a prompt with no terminal, and died — the
# operator asked for unattended and got the opposite. The flags still set 1.
truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | y | on) return 0 ;;
    *) return 1 ;;
  esac
}

ASSUME_YES="${ASSUME_YES:-0}"

# Config writers stage through mktemp, not a predictable "${file}.emisar-new.$$".
# A shell > redirect FOLLOWS a destination symlink and chmod follows it too, so
# under the documented `sudo bash -s -- --uninstall` a local user who pre-created
# that path (the PID space is small enough to blanket) got an arbitrary
# root-written 0600 file with content they controlled. mktemp's template creates
# with O_EXCL and a random suffix, so there is nothing to pre-create.
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

# The supported pre-split release tip keeps its immutable original provenance.
# Pin that exact tag to its workflow commit;
# every other official tag uses the trusted workflow, with no fallback.
select_attestation_policy() {
  ATTESTATION_SIGNER_DIGEST=""
  ATTESTATION_SOURCE_REF=""
  ATTESTATION_DENY_SELF_HOSTED=0
  if [ -n "${ATTESTATION_WORKFLOW}" ] || [ "${REPO}" != "${OFFICIAL_REPO}" ]; then
    return 0
  fi

  ATTESTATION_WORKFLOW="AndrewDryga/emisar/.github/workflows/mcp-release-trusted.yml"
  ATTESTATION_SOURCE_REF="refs/tags/${VERSION}"
  ATTESTATION_DENY_SELF_HOSTED=1
  if [ "${VERSION}" = "mcp-v0.10.1" ]; then
    ATTESTATION_WORKFLOW="AndrewDryga/emisar/.github/workflows/mcp-release.yml"
    ATTESTATION_SIGNER_DIGEST="642128eb48205405fd44ce845118e6a68737eea2"
  fi
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
    --uninstall)   MODE="uninstall"; shift;;
    --yes|-y)      ASSUME_YES=1; shift;;
    --help|-h)     usage; exit 0;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2;;
  esac
done

log()  { printf '\033[1;34m[install-mcp]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install-mcp]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install-mcp]\033[0m %s\n' "$*" >&2; exit 1; }

# Checked here rather than beside the assignment: `die` has to exist first.
safe_config_value "${EMISAR_URL}" ||
  die "EMISAR_URL contains characters that cannot be written to a client config: ${EMISAR_URL}"

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

require_immutable_release() {
  local version="$1" release
  release=$(github_api \
    "https://api.github.com/repos/${REPO}/releases/tags/${version}") \
    || die "could not verify release metadata for ${version}"
  grep -Eq '"immutable"[[:space:]]*:[[:space:]]*true' <<<"$release" || \
    die "release ${version} is mutable and is no longer trusted; install the latest immutable MCP release"
}

resolve_latest_from_github() {
  local releases
  releases=$(github_api "https://api.github.com/repos/${REPO}/releases?per_page=100") || return 1
  printf '%s\n' "${releases}" \
    | tr '{' '\n' \
    | grep -v '"draft":[[:space:]]*true' \
    | grep -v '"prerelease":[[:space:]]*true' \
    | grep -oE '"tag_name":[[:space:]]*"mcp-v[0-9]+\.[0-9]+\.[0-9]+"' \
    | sed -E 's/.*"mcp-v([0-9]+\.[0-9]+\.[0-9]+)".*/\1/' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1 \
    | sed -E 's/^/mcp-v/'
}

release_manifest_tag() {
  local url="$1" component="$2" out tag version revision expected
  out=$(curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --retry 2 -fsSL "$url") || return 1
  printf '%s\n' "$out" | grep -Eq '"schema_version"[[:space:]]*:[[:space:]]*1([,[:space:]}]|$)' || return 2
  printf '%s\n' "$out" | grep -Eq '"component"[[:space:]]*:[[:space:]]*"'"$component"'"' || return 2
  tag=$(printf '%s\n' "$out" | grep -oE '"tag"[[:space:]]*:[[:space:]]*"mcp-v[0-9]+\.[0-9]+\.[0-9]+"' | sed -E 's/.*"(mcp-v[0-9]+\.[0-9]+\.[0-9]+)"/\1/') || return 2
  version=$(printf '%s\n' "$out" | grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)"/\1/') || return 2
  revision=$(printf '%s\n' "$out" | grep -oE '"source_revision"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' | sed -E 's/.*"([0-9a-f]{40})"/\1/') || return 2
  [ "$(printf '%s\n' "$tag" | wc -l | tr -d ' ')" -eq 1 ] || return 2
  [ "$(printf '%s\n' "$version" | wc -l | tr -d ' ')" -eq 1 ] || return 2
  [ "$(printf '%s\n' "$revision" | wc -l | tr -d ' ')" -eq 1 ] || return 2
  expected=${tag#mcp-v}
  [ "$version" = "$expected" ] || return 2
  if printf '%s\n' "$version" | grep -Eq '(^|\.)0[0-9]'; then
    return 2
  fi
  printf '%s\n' "$tag"
}

resolve_latest_version() {
  local version status
  if [ "$REPO" = "$OFFICIAL_REPO" ]; then
    if version=$(release_manifest_tag "${RELEASE_BASE_URL}/latest.json" mcp); then
      printf '%s\n' "$version"
      return 0
    else
      status=$?
      [ "$status" -ne 2 ] || die "the Emisar release mirror returned an invalid MCP latest.json"
      warn "Emisar release mirror unavailable — falling back to the GitHub release mirror"
    fi
  fi
  resolve_latest_from_github
}

mirror_release_base() {
  local version="$1" tag status
  if tag=$(release_manifest_tag "${RELEASE_BASE_URL}/${version}/manifest.json" mcp); then
    [ "$tag" = "$version" ] || return 2
    printf '%s/%s\n' "$RELEASE_BASE_URL" "$version"
    return 0
  else
    status=$?
    [ "$status" -ne 2 ] || return 2
  fi
  return 1
}

github_release_base() {
  local version="$1"
  require_immutable_release "$version"
  printf 'https://github.com/%s/releases/download/%s\n' "$REPO" "$version"
}

fetch_release_files() {
  local base="$1" tmp="$2"
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 -fsSL -o "${tmp}/${TARBALL}" "${base}/${TARBALL}" &&
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 -fsSL -o "${tmp}/SHA256SUMS-MCP" "${base}/SHA256SUMS-MCP"
}

# A named function rather than an inline block, so the behavior suite can drive
# the refusal directly — on a host without `gh` the attestation step degrades to
# a warning, which makes this comparison the only thing standing between a
# tampered download and execution. install.sh's sha_verify is named for the
# same reason.
verify_release_checksum() {
  local tmp="$1" tarball="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    sha_check() { sha256sum -c -; }
  elif command -v shasum >/dev/null 2>&1; then
    sha_check() { shasum -a 256 -c -; }
  else
    die "neither sha256sum nor shasum found — cannot verify download"
  fi

  (
    cd "${tmp}"
    grep -E "  ${tarball}\$" SHA256SUMS-MCP | sha_check
  ) || die "checksum verification failed for ${tarball}"
}

# Same TTY-fallback prompt the runner installer uses — curl|bash makes
# stdin the script content, not a terminal, so a plain `read` consumes
# the next line of the script. See install.sh for the longer rationale.
confirm() {
  if truthy "$ASSUME_YES"; then return 0; fi
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

verify_attestation() {
  local path="$1" name="$2"
  if [ -z "${ATTESTATION_WORKFLOW}" ]; then
    warn "no attestation workflow configured for ${REPO} — skipping provenance check"
    return 0
  fi
  local hint="gh attestation verify <file> --repo ${REPO} --signer-workflow ${ATTESTATION_WORKFLOW}"
  [ -z "${ATTESTATION_SOURCE_REF}" ] || hint="${hint} --source-ref ${ATTESTATION_SOURCE_REF}"
  [ -z "${ATTESTATION_SIGNER_DIGEST}" ] || hint="${hint} --signer-digest ${ATTESTATION_SIGNER_DIGEST}"
  [ "${ATTESTATION_DENY_SELF_HOSTED}" = "0" ] || hint="${hint} --deny-self-hosted-runners"
  if ! command -v gh >/dev/null 2>&1; then
    warn "gh not installed — skipping release attestation check"
    warn "verify it yourself: ${hint}"
    return 0
  fi
  # gh refuses the attestation API unauthenticated — it exits 4 telling you to
  # run `gh auth login` without checking anything. Treating that as a failed
  # verification would make a GitHub login a prerequisite for installing the
  # bridge, so an unauthenticated CLI skips exactly like a missing one.
  if ! gh auth status >/dev/null 2>&1; then
    warn "gh is not authenticated — skipping release attestation check"
    warn "verify it yourself: ${hint}"
    return 0
  fi
  log "verifying release attestation"
  local -a verify_args=(
    attestation verify "${path}"
    --repo "${REPO}"
    --signer-workflow "${ATTESTATION_WORKFLOW}"
  )
  [ -z "${ATTESTATION_SOURCE_REF}" ] || verify_args+=(--source-ref "${ATTESTATION_SOURCE_REF}")
  [ -z "${ATTESTATION_SIGNER_DIGEST}" ] || verify_args+=(--signer-digest "${ATTESTATION_SIGNER_DIGEST}")
  [ "${ATTESTATION_DENY_SELF_HOSTED}" = "0" ] || verify_args+=(--deny-self-hosted-runners)
  if ! gh "${verify_args[@]}" >/dev/null 2>&1; then
    die "release attestation for ${name} did not verify against ${ATTESTATION_WORKFLOW} — refusing to install"
  fi
  log "attestation verified  ${ATTESTATION_WORKFLOW}"
}

# ---------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------
# The reverse of the install path. The bridge removes its own entry, and the
# backup this installer wrote, from every detected LLM client config and drops
# the stored direct-CLI accounts and rotation state; then the binaries go.
# That order is load-bearing: once the binary is gone nothing can clean a
# client config, so a missing or failing bridge is reported, never skipped.
# A key removed from a config keeps working until revoked in the portal. An
# unused installer key stays hidden and expires after 30 days, so the exit line
# explains both cases.

# Run the bridge as the person who invoked sudo, so Go's UserConfigDir, the
# owner-only credential state, and every client config it writes belong to that
# person rather than root.
run_cli_as_invoking_user() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    sudo -H -u "${SUDO_USER}" "${first_bin}" "$@"
  else
    "${first_bin}" "$@"
  fi
}

installed_bridge() {
  local dir
  while IFS= read -r dir; do
    [ -n "${dir}" ] || continue
    if [ -x "${dir}/emisar-mcp" ]; then
      printf '%s\n' "${dir}/emisar-mcp"
      return 0
    fi
  done <<<"${install_dirs}"
  return 1
}

do_uninstall() {
  local dir bin_dst bridge

  log "uninstall target: ${OS}/${ARCH}"
  while IFS= read -r dir; do
    [ -n "${dir}" ] || continue
    if [ -e "${dir}/emisar-mcp" ]; then
      log "  → ${dir}/emisar-mcp"
    fi
  done <<<"${install_dirs}"

  if ! confirm "remove emisar-mcp, all stored CLI accounts, rotation state, and detected LLM client entries?"; then
    die "aborted by user"
  fi

  if bridge=$(installed_bridge); then
    first_bin="${bridge}"
    if ! "${first_bin}" disconnect --help >/dev/null 2>&1; then
      warn "the installed bridge is older than this script and cannot remove its own client entries"
      warn "  reinstall it first (curl -fsSL ${EMISAR_URL}/install-mcp.sh | sudo bash), then re-run --uninstall"
    elif ! run_cli_as_invoking_user disconnect --all --forget --yes; then
      warn "some LLM client entries could not be removed — remove them by hand"
    fi
  else
    warn "no emisar-mcp binary found — LLM client entries and stored accounts were left in place"
  fi

  while IFS= read -r dir; do
    [ -n "${dir}" ] || continue
    bin_dst="${dir}/emisar-mcp"
    if [ -e "${bin_dst}" ] || [ -L "${bin_dst}" ]; then
      if rm -f -- "${bin_dst}" 2>/dev/null; then
        log "removed ${bin_dst}"
      else
        warn "could not remove ${bin_dst} (re-run with sudo)"
      fi
    fi
    # Leftovers from an interrupted upgrade's staging/rollback.
    rm -f -- "${dir}/.emisar-mcp.old."* "${dir}/.emisar-mcp.new."* 2>/dev/null || true
  done <<<"${install_dirs}"

  log "uninstalled — connected keys stay valid until revoked at ${EMISAR_URL}/app/agents; unused installer keys stay hidden and expire after 30 days"
}

# ---------------------------------------------------------------------
# Resolve targets + dispatch
# ---------------------------------------------------------------------

user_home=$(invoking_user_home)
if [ "${INSTALL_DIR_EXPLICIT}" = "0" ]; then
  install_dirs=$(resolve_install_dirs "${user_home}")
else
  install_dirs="${INSTALL_DIR}"
fi

if [ "${MODE}" = "uninstall" ]; then
  do_uninstall
  exit 0
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
  # Take the HIGHEST version, not the first. The API orders by CREATION, so a
  # patch backported to an older line after a newer minor shipped sat at the top
  # and silently DOWNGRADED the bridge on every fresh install — while printing
  # "latest release: mcp-v0.9.1", which was simply untrue. install.sh carries
  # this fix and the incident that produced it; this stream never got it.
  # Sorted numerically field by field: `sort -V` is not portable to every host
  # this runs on, and a lexical sort puts v0.9.0 above v0.10.0.
  #
  # Assign first, then pipe, so a failed API call is distinguishable from a
  # successful one with no matching release.
  VERSION=$(resolve_latest_version) || die "could not resolve latest MCP release"
  [ -n "${VERSION}" ] || die "no mcp-v* release found yet"
  log "latest release: ${VERSION}"
else
  log "pinned release: ${VERSION}"
fi
[[ "${VERSION}" =~ ^mcp-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  die "release version must match mcp-vMAJOR.MINOR.PATCH (got '${VERSION}')"
select_attestation_policy

VERSION_NUM="${VERSION#mcp-v}"
TAR_NAME="emisar-mcp-${VERSION_NUM}-${OS}-${ARCH}"
TARBALL="${TAR_NAME}.tar.gz"
BASE_URL=""
RELEASE_SOURCE=""
if [ "$REPO" = "$OFFICIAL_REPO" ]; then
  if BASE_URL=$(mirror_release_base "$VERSION"); then
    RELEASE_SOURCE="Emisar release mirror"
  else
    status=$?
    [ "$status" -ne 2 ] || die "the Emisar release mirror returned an invalid manifest for ${VERSION}"
  fi
fi
if [ -z "$BASE_URL" ]; then
  BASE_URL=$(github_release_base "$VERSION") || die "could not verify GitHub release mirror metadata for ${VERSION}"
  RELEASE_SOURCE="GitHub release mirror"
fi

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

log "downloading ${TARBALL} from ${RELEASE_SOURCE}"
if ! fetch_release_files "$BASE_URL" "$tmp"; then
  if [ "$RELEASE_SOURCE" != "Emisar release mirror" ]; then
    die "failed to download ${VERSION} from ${BASE_URL}"
  fi
  warn "Emisar release download failed — falling back to the GitHub release mirror"
  rm -f "${tmp}/${TARBALL}" "${tmp}/SHA256SUMS-MCP"
  BASE_URL=$(github_release_base "$VERSION") || die "could not verify GitHub release mirror metadata for ${VERSION}"
  fetch_release_files "$BASE_URL" "$tmp" || die "failed to download ${VERSION} from both release mirrors"
fi

log "verifying checksum"
# sha_value is the staging/activation integrity helper used further down;
# verify_release_checksum owns the download comparison itself.
if command -v sha256sum >/dev/null 2>&1; then
  sha_value() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha_value() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  die "neither sha256sum nor shasum found — cannot verify download"
fi

verify_release_checksum "${tmp}" "${TARBALL}"

# The checksum proves the tarball matches SHA256SUMS-MCP; it says nothing about
# who produced either, since both come from the same release. The Sigstore build
# provenance does: it binds these bytes to a run of our release workflow on a
# GitHub-hosted runner. Pinning the signer workflow is what makes that a real
# check — without it, any attestation from any workflow in the repo passes.
#
verify_attestation "${tmp}/${TARBALL}" "${TARBALL}"

log "extracting"
# --no-same-owner/--no-same-permissions: the archive's recorded uid/gid and mode
# bits are not a trust input; the install path sets what it needs explicitly.
tar -C "${tmp}" --no-same-owner --no-same-permissions -xzf "${tmp}/${TARBALL}"

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
# Hand the connection phase to the installed bridge
# ---------------------------------------------------------------------
# `emisar-mcp connect` detects the LLM clients installed for this user, offers
# each one individually, and leaves a client that already carries an emisar
# entry untouched (so the portal's upgrade one-liner stays quiet). The API keys
# come from one device-grant approval (RFC 8628 shape): the operator approves
# the printed link in the portal and the poll delivers the keys straight into
# the bridge's own credential state and the client configs — no secret ever
# touches argv, env, history, or sudo's syslog. This script only places the
# binary and hands over the terminal.

tty_available() {
  [ -t 0 ] && return 0
  if { exec 3</dev/tty; } 2>/dev/null; then
    exec 3<&-
    return 0
  fi
  return 1
}

# The same truthy contract controls both the install confirmation and whether
# the unattended path may hand off to an interactive browser flow.
interactive_connect_available() {
  ! truthy "${ASSUME_YES}" && tty_available
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

# Secondary/reference lines (the verify/uninstall footer) — faint on a
# terminal, plain otherwise.
dim() {
  if [ -t 1 ]; then
    printf '\033[2m%s\033[0m\n' "$*"
  else
    printf '%s\n' "$*"
  fi
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

# The bridge owns the connection phase: it detects the LLM clients installed
# for this user, runs ONE browser approval covering the direct CLI and every
# client the operator picks, and writes each client's own config shape. Give it
# the terminal explicitly — under the documented `curl … | sudo bash` this
# script's own stdin is the pipe, not the operator.
if interactive_connect_available; then
  run_cli_as_invoking_user connect --url "${EMISAR_URL}" </dev/tty ||
    warn "connection setup did not finish — run 'emisar-mcp connect', or use the manual snippets at ${EMISAR_URL}/app/agents/connect"
else
  out ""
  out "Connect this machine and your LLM clients: emisar-mcp connect"
  out "Manual client snippets: ${EMISAR_URL}/app/agents/connect"
fi

out ""
dim "Verify install:"
dim "  ${first_bin} --help"
out ""
dim "Uninstall:"
dim "  curl -fsSL https://emisar.dev/install-mcp.sh | sudo bash -s -- --uninstall"

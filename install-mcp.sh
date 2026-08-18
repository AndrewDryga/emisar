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
#   curl --proto '=https' --proto-redir '=https' --globoff -fsSL https://emisar.dev/install-mcp.sh | sudo bash
#
#   # Pin a version:
#   curl --proto '=https' --proto-redir '=https' --globoff -fsSL https://.../install-mcp.sh | sudo bash -s -- --version mcp-v0.1.0
#
#   # Install to a per-user location (no sudo):
#   curl --proto '=https' --proto-redir '=https' --globoff -fsSL https://.../install-mcp.sh | INSTALL_DIR=$HOME/.local/bin bash
#
#   # Uninstall — binary, client-config entries, and rotated-key state:
#   curl --proto '=https' --proto-redir '=https' --globoff -fsSL https://.../install-mcp.sh | sudo bash -s -- --uninstall
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
# Matched literally against the signing certificate's SubjectAlternativeName,
# which carries GitHub's canonical owner casing (AndrewDryga) — NOT the
# lowercase spelling REPO uses. Deriving this from REPO reads as obviously
# correct and fails every verification, so it is written out. A fork gets no
# default: pinning ours would fail their install, so they set their own or the
# checksum stands alone.
ATTESTATION_WORKFLOW="${EMISAR_ATTESTATION_WORKFLOW:-}"
if [ -z "${ATTESTATION_WORKFLOW}" ] && [ "${REPO}" = "andrewdryga/emisar" ]; then
  ATTESTATION_WORKFLOW="AndrewDryga/emisar/.github/workflows/mcp-release.yml"
fi
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
                      and the bridge's rotated-key state. Removed API keys
                      stay valid until revoked on the portal's /app/agents.
  --yes               Skip the confirmation prompt and the interactive
                      LLM-client setup.
  --help              This message.

Env vars accepted: VERSION, INSTALL_DIR, EMISAR_REPO, EMISAR_GITHUB_TOKEN,
ASSUME_YES, EMISAR_URL (the portal the bridge talks to; default
https://emisar.dev — a self-hosted portal's install command sets it).
USAGE
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

# ---------------------------------------------------------------------
# LLM client detection (shared by install + uninstall)
# ---------------------------------------------------------------------

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

# The one list of supported clients: which are present on this machine and
# whether each already carries emisar. Install offers the candidates;
# uninstall cleans the connected ones.
scan_llm_clients() {
  local user_home="$1" desktop_dir
  CLIENTS_FOUND=0
  SCANNED=""

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
}

# ---------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------
# The reverse of the install path: drop the emisar entry from each detected
# client config (and the install's .emisar-bak files), remove the bridge's
# rotated-key state, then the binaries. A key removed from a config keeps
# working until revoked in the portal, so the exit line points at /app/agents.

# Reverse of merge_json_config, same python3-then-jq ladder: drop the emisar
# member while preserving every other key — and, for a JSONC file, its
# comments, via a textual cut since json.dump would reformat them away.
# jq covers only the standard mcpServers shape on comment-free JSON.
remove_json_emisar() {
  local file="$1" shape="${2:-std}"
  local status=0
  if command -v python3 >/dev/null 2>&1; then
    MCP_FILE="${file}" MCP_SHAPE="${shape}" python3 - 2>/dev/null <<'PY' || status=1
import json, os, re, tempfile

# Same scanner helpers as the merge in merge_json_config: parse+delete+dump
# for plain JSON (all shapes), and a comment-preserving textual cut for a
# file that actually has comments.

def strip_jsonc(text):
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            out.append(c)
            i += 1
            while i < n:
                out.append(text[i])
                if text[i] == '\\' and i + 1 < n:
                    out.append(text[i + 1])
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            while i < n and text[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            i += 2
            while i + 1 < n and not (text[i] == '*' and text[i + 1] == '/'):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return re.sub(r',(\s*[}\]])', r'\1', ''.join(out))

def has_comments(text):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n:
                if text[i] == '\\':
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] in '/*':
            return True
        i += 1
    return False

def skip_ws_comments(raw, i, n):
    while i < n:
        c = raw[i]
        if c in ' \t\r\n':
            i += 1
        elif c == '/' and i + 1 < n and raw[i + 1] == '/':
            while i < n and raw[i] != '\n':
                i += 1
        elif c == '/' and i + 1 < n and raw[i + 1] == '*':
            i += 2
            while i + 1 < n and not (raw[i] == '*' and raw[i + 1] == '/'):
                i += 1
            i += 2
        else:
            break
    return i

def match_string(raw, i, n):
    i += 1
    while i < n:
        if raw[i] == '\\':
            i += 2
            continue
        if raw[i] == '"':
            return i + 1
        i += 1
    return i

def find_close(raw, i, n, open_ch, close_ch):
    depth = 0
    while i < n:
        c = raw[i]
        if c == '"':
            i = match_string(raw, i, n)
            continue
        if c == '/' and i + 1 < n and raw[i + 1] in '/*':
            i = skip_ws_comments(raw, i, n)
            continue
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1

def skip_value(raw, i, n):
    i = skip_ws_comments(raw, i, n)
    if i >= n:
        return i
    c = raw[i]
    if c == '"':
        return match_string(raw, i, n)
    if c == '{':
        return find_close(raw, i, n, '{', '}') + 1
    if c == '[':
        return find_close(raw, i, n, '[', ']') + 1
    while i < n and raw[i] not in ',}]':
        i += 1
    return i

def find_key_value_brace(raw, obj_brace, n, key):
    end = find_close(raw, obj_brace, n, '{', '}')
    if end < 0:
        return None
    i = obj_brace + 1
    target = '"' + key + '"'
    while i < end:
        c = raw[i]
        if c in ' \t\r\n,':
            i += 1
            continue
        if c == '/' and i + 1 < n and raw[i + 1] in '/*':
            i = skip_ws_comments(raw, i, n)
            continue
        if c == '"':
            key_end = match_string(raw, i, n)
            member = raw[i:key_end]
            j = skip_ws_comments(raw, key_end, n)
            if j < n and raw[j] == ':':
                j = skip_ws_comments(raw, j + 1, n)
                if member == target:
                    return j if (j < n and raw[j] == '{') else -1
                i = skip_value(raw, j, n)
                continue
            i = key_end
            continue
        i += 1
    return None

def member_span(raw, obj_brace, n, name):
    end_obj = find_close(raw, obj_brace, n, '{', '}')
    if end_obj < 0:
        raise SystemExit('unterminated container object')
    i = obj_brace + 1
    target = '"' + name + '"'
    prev_comma = -1
    while i < end_obj:
        c = raw[i]
        if c in ' \t\r\n':
            i += 1
            continue
        if c == ',':
            prev_comma = i
            i += 1
            continue
        if c == '/' and i + 1 < n and raw[i + 1] in '/*':
            i = skip_ws_comments(raw, i, n)
            continue
        if c == '"':
            key_start = i
            key_end = match_string(raw, i, n)
            member = raw[i:key_end]
            j = skip_ws_comments(raw, key_end, n)
            if j < n and raw[j] == ':':
                value_end = skip_value(raw, j + 1, n)
                if member == target:
                    k = skip_ws_comments(raw, value_end, n)
                    if k < end_obj and raw[k] == ',':
                        return key_start, k + 1
                    if prev_comma >= 0:
                        return prev_comma, value_end
                    return key_start, value_end
                i = value_end
                continue
            i = key_end
            continue
        i += 1
    raise SystemExit('no emisar member to remove')

def widen_to_lines(raw, start, end, n):
    # A member cut mid-file leaves its indentation and newline behind; when
    # the span covers whole lines, cut those instead so no blank line remains.
    ls = raw.rfind('\n', 0, start) + 1
    if raw[ls:start].strip() == '' and end < n and raw[end] == '\n':
        return ls, end + 1
    return start, end

def shape_container(shape):
    if shape in ('std', 'copilot'):
        return ['mcpServers']
    if shape == 'openclaw':
        return ['mcp', 'servers']
    if shape == 'opencode':
        return ['mcp']
    if shape == 'zed':
        return ['context_servers']
    raise SystemExit('unknown shape: ' + shape)

def main():
    path = os.environ['MCP_FILE']
    keys = shape_container(os.environ['MCP_SHAPE'])
    with open(path) as handle:
        raw = handle.read()
    if has_comments(raw):
        # Only a 1-level container is cut textually — the same limit as the
        # merge, so anything install could write, uninstall can remove.
        if len(keys) != 1:
            raise SystemExit('cannot edit a commented multi-level config')
        n = len(raw)
        root = skip_ws_comments(raw, 0, n)
        if root >= n or raw[root] != '{':
            raise SystemExit('top-level JSON is not an object')
        vb = find_key_value_brace(raw, root, n, keys[0])
        if vb is None or vb == -1:
            raise SystemExit('no container object: ' + keys[0])
        start, end = member_span(raw, vb, n, 'emisar')
        start, end = widen_to_lines(raw, start, end, n)
        out = raw[:start] + raw[end:]
        check = json.loads(strip_jsonc(out))
        for k in keys:
            check = check.get(k)
            if not isinstance(check, dict):
                raise SystemExit('validation failed after removal')
        if 'emisar' in check:
            raise SystemExit('validation failed after removal')
    else:
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise SystemExit('top-level JSON is not an object')
        node = data
        for k in keys:
            node = node.get(k) if isinstance(node, dict) else None
            if not isinstance(node, dict):
                raise SystemExit('no container object: ' + k)
        if 'emisar' not in node:
            raise SystemExit('no emisar member to remove')
        del node['emisar']
        out = json.dumps(data, indent=2) + '\n'
    fd, tmp = tempfile.mkstemp(prefix='.emisar-mcp.', dir=os.path.dirname(path) or '.')
    with os.fdopen(fd, 'w') as handle:
        handle.write(out)
    os.replace(tmp, path)

main()
PY
    return "${status}"
  fi
  [ "${shape}" = "std" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    local tmp_out; tmp_out="$(mktemp "${file}.emisar-new.XXXXXX")"
    jq 'del(.mcpServers.emisar)' "${file}" >"${tmp_out}" 2>/dev/null || status=1
    if [ "${status}" -eq 0 ]; then
      chmod 0600 "${tmp_out}" && mv "${tmp_out}" "${file}" && return 0
    fi
    rm -f "${tmp_out}"
    return 1
  fi
  return 1
}

# Reverse of append_codex_toml: drop the [mcp_servers.emisar] table — its
# exact header through the next table header or EOF.
remove_codex_toml_emisar() {
  local file="$1"
  local tmp_out; tmp_out="$(mktemp "${file}.emisar-new.XXXXXX")"
  awk '
    /^\[mcp_servers\.emisar\]$/ { skip = 1; next }
    /^\[/ { skip = 0 }
    { if (!skip) print }
  ' "${file}" >"${tmp_out}" || { rm -f "${tmp_out}"; return 1; }
  { chmod 0600 "${tmp_out}" && mv "${tmp_out}" "${file}"; } || { rm -f "${tmp_out}"; return 1; }
  ! toml_config_has_emisar "${file}"
}

# Reverse of append_yaml_config: drop the emisar entry under the client's
# top-level key (hermes: mcp_servers, goose: extensions) — and the key
# itself once it has no other children, so a later install can append again.
remove_yaml_emisar() {
  local kind="$1" file="$2"
  local top tmp_out
  case "${kind}" in
    hermes) top="mcp_servers" ;;
    goose) top="extensions" ;;
    *) return 1 ;;
  esac
  tmp_out="$(mktemp "${file}.emisar-new.XXXXXX")"
  awk -v top="${top}" '
    {
      if (skip) {
        if ($0 ~ /^[ \t]*$/) next
        match($0, /^[ \t]*/)
        if (RLENGTH > ind) next
        skip = 0
      }
      if ($0 !~ /^[ \t]/ && $0 !~ /^[ \t]*$/) in_top = ($0 ~ "^" top ":")
      if (in_top && $0 ~ /^[ \t]+emisar:[ \t]*$/) {
        match($0, /^[ \t]*/)
        ind = RLENGTH
        skip = 1
        next
      }
      lines[++count] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        if (lines[i] ~ "^" top ":[ \t]*$") {
          j = i + 1
          while (j <= count && lines[j] ~ /^[ \t]*$/) j++
          if (j > count || lines[j] !~ /^[ \t]/) continue
        }
        print lines[i]
      }
    }
  ' "${file}" >"${tmp_out}" || { rm -f "${tmp_out}"; return 1; }
  { chmod 0600 "${tmp_out}" && mv "${tmp_out}" "${file}"; } || { rm -f "${tmp_out}"; return 1; }
  ! yaml_config_has_emisar "${file}"
}

# Kind → removal, mirroring install_client_config's kind → merge mapping.
remove_client_config() {
  local kind="$1" config_file="$2"
  case "${kind}" in
    json) remove_json_emisar "${config_file}" std ;;
    opencode|openclaw|copilot|zed)
      # Non-standard JSON schemas need the real removal — python3 only.
      command -v python3 >/dev/null 2>&1 || return 1
      remove_json_emisar "${config_file}" "${kind}"
      ;;
    toml) remove_codex_toml_emisar "${config_file}" ;;
    hermes|goose) remove_yaml_emisar "${kind}" "${config_file}" ;;
    *) return 1 ;;
  esac
}

# The bridge's rotated-key state (mcp rotate.go, under Go's UserConfigDir).
# Removed like the runner uninstall removes its cached token + identity.
remove_credential_state() {
  local user_home="$1" config_root
  [ -n "${user_home}" ] || return 0
  case "${OS}" in
    darwin) config_root="${user_home}/Library/Application Support" ;;
    *) config_root="${XDG_CONFIG_HOME:-${user_home}/.config}" ;;
  esac
  if [ -d "${config_root}/emisar/credentials" ]; then
    rm -rf "${config_root}/emisar/credentials"
    log "removed rotated-key state ${config_root}/emisar/credentials"
  fi
}

do_uninstall() {
  local user_home="$1" dir bin_dst label client_id kind config_file state

  log "uninstall target: ${OS}/${ARCH}"
  while IFS= read -r dir; do
    [ -n "${dir}" ] || continue
    if [ -e "${dir}/emisar-mcp" ]; then
      log "  → ${dir}/emisar-mcp"
    fi
  done <<<"${install_dirs}"

  if ! confirm "remove emisar-mcp and the emisar entry in detected LLM client configs?"; then
    die "aborted by user"
  fi

  scan_llm_clients "${user_home}"
  while IFS='|' read -r label client_id kind config_file state; do
    [ -n "${client_id}" ] || continue
    if [ "${state}" = "connected" ]; then
      if remove_client_config "${kind}" "${config_file}"; then
        own_config_file "${config_file}"
        log "removed emisar from ${label}: ${config_file}"
      else
        warn "${label}: could not remove the emisar entry from ${config_file} — remove it by hand"
      fi
    fi
    if [ -e "${config_file}.emisar-bak" ]; then
      rm -f "${config_file}.emisar-bak" && log "removed backup ${config_file}.emisar-bak"
    fi
  done <<<"${SCANNED}"

  remove_credential_state "${user_home}"

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

  log "uninstalled — removed keys stay valid until revoked: ${EMISAR_URL}/app/agents"
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
  do_uninstall "${user_home}"
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
  releases=$(github_api "https://api.github.com/repos/${REPO}/releases?per_page=100") \
    || die "could not query GitHub releases API"
  VERSION=$(
    printf '%s\n' "${releases}" \
      | tr '{' '\n' \
      | grep -v '"draft":[[:space:]]*true' \
      | grep -v '"prerelease":[[:space:]]*true' \
      | grep -oE '"tag_name":[[:space:]]*"mcp-v[0-9]+\.[0-9]+\.[0-9]+"' \
      | sed -E 's/.*"mcp-v([0-9]+\.[0-9]+\.[0-9]+)".*/\1/' \
      | sort -t. -k1,1n -k2,2n -k3,3n \
      | tail -1 \
      | sed -E 's/^/mcp-v/'
  )
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
curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 -fsSL -o "${tmp}/${TARBALL}" "${BASE_URL}/${TARBALL}" \
  || die "download failed: ${BASE_URL}/${TARBALL}"

log "downloading SHA256SUMS-MCP"
curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 -fsSL -o "${tmp}/SHA256SUMS-MCP" "${BASE_URL}/SHA256SUMS-MCP" \
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

# The checksum proves the tarball matches SHA256SUMS-MCP; it says nothing about
# who produced either, since both come from the same release. The Sigstore build
# provenance does: it binds these bytes to a run of our release workflow on a
# GitHub-hosted runner. Pinning the signer workflow is what makes that a real
# check — without it, any attestation from any workflow in the repo passes.
#
# Verification runs only when a verifier is installed. Requiring one would break
# installing on a bare machine, which is the common case, so a missing verifier
# warns and continues on the checksum alone. A verifier that IS present and says
# no fails the install.
if [ -z "${ATTESTATION_WORKFLOW}" ]; then
  warn "no attestation workflow configured for ${REPO} — skipping provenance check"
elif ! command -v gh >/dev/null 2>&1; then
  warn "gh not installed — skipping release attestation check"
  warn "verify it yourself: gh attestation verify <file> --repo ${REPO} --signer-workflow ${ATTESTATION_WORKFLOW}"
# gh refuses the attestation API unauthenticated — it exits 4 telling you to run
# `gh auth login` without checking anything. Treating that as a failed
# verification would make a GitHub login a prerequisite for installing the
# bridge, so an unauthenticated CLI skips exactly like a missing one.
elif ! gh auth status >/dev/null 2>&1; then
  warn "gh is not authenticated — skipping release attestation check"
  warn "verify it yourself: gh attestation verify <file> --repo ${REPO} --signer-workflow ${ATTESTATION_WORKFLOW}"
else
  log "verifying release attestation"
  gh attestation verify "${tmp}/${TARBALL}" --repo "${REPO}" \
    --signer-workflow "${ATTESTATION_WORKFLOW}" >/dev/null 2>&1 \
    || die "release attestation for ${TARBALL} did not verify against ${ATTESTATION_WORKFLOW} — refusing to install"
  log "attestation verified  ${ATTESTATION_WORKFLOW}"
fi

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

# The portal supplies the verification URI, and we both PRINT it to the operator
# and hand it to `open`/`xdg-open` — which on macOS launches whatever
# application has registered the scheme. A compromised portal answering with
# `file:///…`, or a custom scheme some installed app claims, would run something
# on the operator's machine off the back of an install. A raw ESC in the string
# would separately rewrite what their terminal shows them.
#
# It has to be an https URL on the portal's own origin, which is what a
# verification URI is by definition. `?` `=` `&` `%` are in the set because the
# complete form carries the code as a query parameter.
safe_verification_uri() {
  case "$1" in
    "${EMISAR_URL}"/*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._:/?=\&@%+-]*) return 1 ;;
  esac
  return 0
}

# The user code is read aloud and typed by hand, so it is alphanumerics and
# dashes. Filtered for the same reason: it is printed straight to a terminal.
safe_user_code() {
  case "$1" in
    "") return 1 ;;
    *[!A-Za-z0-9-]*) return 1 ;;
  esac
  return 0
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

file_has_content() {
  [ -e "$1" ] && grep -q '[^[:space:]]' "$1" 2>/dev/null
}

# printf-assembled (not a heredoc) so no line is a bare `}` — the CI
# smoke harness extracts functions by their closing column-0 brace.
write_fresh_json_config() {
  local file="$1" bin="$2" url="$3" key="$4" client="$5"
  local tmp_out; tmp_out="$(mktemp "${file}.emisar-new.XXXXXX")"
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

# Merge into an existing JSON config, preserving every other key — and, for a
# JSONC file (Zed and VS Code ship commented settings), its comments and
# trailing commas, via a textual insert since json.dump would reformat them
# away. Writes the client's exact upstream schema (`shape`). python3 first; jq
# covers only the standard mcpServers shape on comment-free JSON; no tool, or a
# commented multi-level config → fail so the caller prints the manual path.
merge_json_config() {
  local file="$1" bin="$2" url="$3" key="$4" client="$5" shape="${6:-std}"
  local status=0
  if command -v python3 >/dev/null 2>&1; then
    MCP_FILE="${file}" MCP_BIN="${bin}" MCP_URL="${url}" MCP_KEY="${key}" \
      MCP_CLIENT="${client}" MCP_SHAPE="${shape}" python3 - 2>/dev/null <<'PY' || status=1
import json, os, re, tempfile

# A rich editor config (Zed, VS Code) is JSONC — it carries // and /* */
# comments and trailing commas. Strict json.loads dies on it, and json.dump
# would strip the user's comments even if it parsed. So: parse+dump for plain
# JSON (unchanged, all shapes), and a comment-preserving textual insert for a
# file that actually has comments.

def strip_jsonc(text):
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            out.append(c)
            i += 1
            while i < n:
                out.append(text[i])
                if text[i] == '\\' and i + 1 < n:
                    out.append(text[i + 1])
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            while i < n and text[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            i += 2
            while i + 1 < n and not (text[i] == '*' and text[i + 1] == '/'):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return re.sub(r',(\s*[}\]])', r'\1', ''.join(out))

def has_comments(text):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n:
                if text[i] == '\\':
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] in '/*':
            return True
        i += 1
    return False

def skip_ws_comments(raw, i, n):
    while i < n:
        c = raw[i]
        if c in ' \t\r\n':
            i += 1
        elif c == '/' and i + 1 < n and raw[i + 1] == '/':
            while i < n and raw[i] != '\n':
                i += 1
        elif c == '/' and i + 1 < n and raw[i + 1] == '*':
            i += 2
            while i + 1 < n and not (raw[i] == '*' and raw[i + 1] == '/'):
                i += 1
            i += 2
        else:
            break
    return i

def match_string(raw, i, n):
    i += 1
    while i < n:
        if raw[i] == '\\':
            i += 2
            continue
        if raw[i] == '"':
            return i + 1
        i += 1
    return i

def find_close(raw, i, n, open_ch, close_ch):
    depth = 0
    while i < n:
        c = raw[i]
        if c == '"':
            i = match_string(raw, i, n)
            continue
        if c == '/' and i + 1 < n and raw[i + 1] in '/*':
            i = skip_ws_comments(raw, i, n)
            continue
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1

def skip_value(raw, i, n):
    i = skip_ws_comments(raw, i, n)
    if i >= n:
        return i
    c = raw[i]
    if c == '"':
        return match_string(raw, i, n)
    if c == '{':
        return find_close(raw, i, n, '{', '}') + 1
    if c == '[':
        return find_close(raw, i, n, '[', ']') + 1
    while i < n and raw[i] not in ',}]':
        i += 1
    return i

def find_key_value_brace(raw, obj_brace, n, key):
    end = find_close(raw, obj_brace, n, '{', '}')
    if end < 0:
        return None
    i = obj_brace + 1
    target = '"' + key + '"'
    while i < end:
        c = raw[i]
        if c in ' \t\r\n,':
            i += 1
            continue
        if c == '/' and i + 1 < n and raw[i + 1] in '/*':
            i = skip_ws_comments(raw, i, n)
            continue
        if c == '"':
            key_end = match_string(raw, i, n)
            member = raw[i:key_end]
            j = skip_ws_comments(raw, key_end, n)
            if j < n and raw[j] == ':':
                j = skip_ws_comments(raw, j + 1, n)
                if member == target:
                    return j if (j < n and raw[j] == '{') else -1
                i = skip_value(raw, j, n)
                continue
            i = key_end
            continue
        i += 1
    return None

def member_indent(raw, brace):
    ls = raw.rfind('\n', 0, brace) + 1
    base = re.match(r'[ \t]*', raw[ls:brace]).group(0)
    return base + '  '

def render_member(name, value, indent):
    lines = json.dumps(value, indent=2).split('\n')
    rendered = lines[0] + ''.join('\n' + indent + ln for ln in lines[1:])
    return '"' + name + '": ' + rendered

def insert_1level(raw, container, name, value):
    n = len(raw)
    root = skip_ws_comments(raw, 0, n)
    if root >= n or raw[root] != '{':
        raise SystemExit('top-level JSON is not an object')
    vb = find_key_value_brace(raw, root, n, container)
    if vb == -1:
        raise SystemExit('container key is not an object: ' + container)
    if vb is not None:
        if find_key_value_brace(raw, vb, n, name) is not None:
            return raw
        indent = member_indent(raw, vb)
        j = skip_ws_comments(raw, vb + 1, n)
        empty = j < n and raw[j] == '}'
        block = '\n' + indent + render_member(name, value, indent) + ('' if empty else ',')
        return raw[:vb + 1] + block + raw[vb + 1:]
    indent = member_indent(raw, root)
    inner = indent + '  '
    j = skip_ws_comments(raw, root + 1, n)
    empty = j < n and raw[j] == '}'
    entry = render_member(name, value, inner)
    block = '\n' + indent + '"' + container + '": {\n' + inner + entry + '\n' + indent + '}' + ('' if empty else ',')
    return raw[:root + 1] + block + raw[root + 1:]

def shape_target(shape, bin_path, entry_env):
    if shape == 'std':
        return ['mcpServers'], {'command': bin_path, 'env': entry_env}
    if shape == 'openclaw':
        return ['mcp', 'servers'], {'command': bin_path, 'env': entry_env}
    if shape == 'opencode':
        return ['mcp'], {'type': 'local', 'command': [bin_path], 'enabled': True, 'environment': entry_env}
    if shape == 'copilot':
        return ['mcpServers'], {'type': 'local', 'command': bin_path, 'args': [], 'env': entry_env, 'tools': ['*']}
    if shape == 'zed':
        return ['context_servers'], {'source': 'custom', 'command': bin_path, 'args': [], 'env': entry_env}
    raise SystemExit('unknown shape: ' + shape)

def main():
    path = os.environ['MCP_FILE']
    with open(path) as handle:
        raw = handle.read()
    entry_env = {
        'EMISAR_URL': os.environ['MCP_URL'],
        'EMISAR_API_KEY': os.environ['MCP_KEY'],
        'EMISAR_CLIENT': os.environ['MCP_CLIENT'],
    }
    keys, value = shape_target(os.environ['MCP_SHAPE'], os.environ['MCP_BIN'], entry_env)
    if has_comments(raw):
        # Only a 1-level container merges textually; a commented multi-level
        # config is rare and falls back to the manual snippet.
        if len(keys) != 1:
            raise SystemExit('cannot merge a commented multi-level config')
        out = insert_1level(raw, keys[0], 'emisar', value)
        check = json.loads(strip_jsonc(out))
        for k in keys:
            check = check[k]
        if check.get('emisar') != value:
            raise SystemExit('validation failed after insert')
    else:
        data = json.loads(raw) if raw.strip() else {}
        if not isinstance(data, dict):
            raise SystemExit('top-level JSON is not an object')
        node = data
        for k in keys:
            node = node.setdefault(k, {})
            if not isinstance(node, dict):
                raise SystemExit('existing config key is not an object: ' + k)
        node['emisar'] = value
        out = json.dumps(data, indent=2) + '\n'
    fd, tmp = tempfile.mkstemp(prefix='.emisar-mcp.', dir=os.path.dirname(path) or '.')
    with os.fdopen(fd, 'w') as handle:
        handle.write(out)
    os.replace(tmp, path)

main()
PY
    return "${status}"
  fi
  [ "${shape}" = "std" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    local tmp_out; tmp_out="$(mktemp "${file}.emisar-new.XXXXXX")"
    # Key rides the environment, not --arg: argv is world-readable /proc/PID/cmdline.
    MCP_KEY="${key}" jq --arg cmd "${bin}" --arg url "${url}" --arg client "${client}" \
      '.mcpServers.emisar = {command: $cmd, env: {EMISAR_URL: $url, EMISAR_API_KEY: env.MCP_KEY, EMISAR_CLIENT: $client}}' \
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
  local tmp_out; tmp_out="$(mktemp "${file}.emisar-new.XXXXXX")"
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
  tmp_out="$(mktemp "${file}.emisar-new.XXXXXX")"
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
        # Stage and move, like every other writer here. A bare `>` redirect
        # FOLLOWS a destination symlink — the exact shape this file's header
        # declares fixed — and this runs as root against the operator's own
        # home under the documented sudo invocation.
        seed_tmp="$(mktemp "${config_file}.emisar-new.XXXXXX")" || return 1
        printf '{}\n' >"${seed_tmp}" || { rm -f "${seed_tmp}"; return 1; }
        mv -f "${seed_tmp}" "${config_file}" || { rm -f "${seed_tmp}"; return 1; }
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

# RFC 8628 leaves interval/expires_in to the server, and each lands on a hot
# surface: bash arithmetic (which evaluates a variable's own content as an
# expression, so `x[$(cmd)]` would execute) and sleep's argv (where a
# non-number fails instantly and hot-loops the poll). Only a bounded plain
# decimal passes; any other shape falls back to the RFC-shaped default.
# LC_ALL=C pins the digit classification to ASCII, as in the poll loop.
bounded_decimal_field() {
  local value="$1" min="$2" max="$3" fallback="$4" LC_ALL=C
  case "${value}" in
    ''|*[!0-9]*) printf '%s\n' "${fallback}"; return 0 ;;
  esac
  # Longer than max means out of bounds; checking before arithmetic also
  # keeps a huge digit string from wrapping intmax. 10# below defuses the
  # octal reading of a leading zero.
  if [ "${#value}" -gt "${#max}" ]; then
    printf '%s\n' "${fallback}"
    return 0
  fi
  value=$((10#${value}))
  if [ "${value}" -lt "${min}" ] || [ "${value}" -gt "${max}" ]; then
    printf '%s\n' "${fallback}"
    return 0
  fi
  printf '%s\n' "${value}"
}

# True only for a JSON body carrying the client_keys map — the portal's
# actual approval verdict. A proxy can answer 200 with its own page, and
# announcing that as approved would end polling with no keys delivered.
json_has_client_keys() {
  local file="$1"
  local status=0
  if command -v python3 >/dev/null 2>&1; then
    MCP_JSON_FILE="${file}" python3 - 2>/dev/null <<'PY' || status=1
import json, os

def main():
    with open(os.environ["MCP_JSON_FILE"]) as handle:
        data = json.load(handle)
    if not isinstance(data, dict) or not isinstance(data.get("client_keys"), dict):
        raise SystemExit(1)

main()
PY
    return "${status}"
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -e '.client_keys | type == "object"' "${file}" >/dev/null 2>&1
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
  safe_user_code "${DEVICE_USER_CODE}" || return 1
  DEVICE_VERIFY_URI=$(json_string_field "${DEVICE_RESP}" verification_uri_complete) || return 1
  # Degrade to the portal's own activation page rather than refusing the
  # install: the operator can still type the code by hand.
  safe_verification_uri "${DEVICE_VERIFY_URI}" ||
    DEVICE_VERIFY_URI="${EMISAR_URL}/activate"
  DEVICE_INTERVAL=$(json_string_field "${DEVICE_RESP}" interval) || DEVICE_INTERVAL=""
  DEVICE_INTERVAL=$(bounded_decimal_field "${DEVICE_INTERVAL}" 1 120 5)
  DEVICE_EXPIRES_IN=$(json_string_field "${DEVICE_RESP}" expires_in) || DEVICE_EXPIRES_IN=""
  DEVICE_EXPIRES_IN=$(bounded_decimal_field "${DEVICE_EXPIRES_IN}" 60 3600 900)
}

# Polls the token endpoint until approval (0; TOKEN_RESP holds the keys)
# or a terminal poll error. Only an HTTP 400 body carries a poll verdict
# (RFC 8628 rides OAuth's 400 error envelope), and of those only
# authorization_pending retries; network blips, rate limits, and proxy
# responses on any other status keep polling. LC_ALL=C pins the charset
# classification below to ASCII regardless of the operator's locale.
await_device_approval() {
  local deadline now status error LC_ALL=C
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
    # Body via stdin so the single-use code stays off argv; the explicit printf
    # producer (never bare -d @-) keeps curl off the script's stdin under curl|sh.
    status=$(printf '{"device_code":"%s"}' "${DEVICE_CODE}" | curl -sS -m 15 \
      -H 'Content-Type: application/json' --data-binary @- \
      -o "${TOKEN_RESP}" -w '%{http_code}' \
      "${EMISAR_URL}/api/mcp/device_token") || continue
    if [ "${status}" = "200" ]; then
      # Only a body carrying the client_keys map is the portal's approval;
      # a proxy's own 200 page keeps polling like any other transport noise.
      json_has_client_keys "${TOKEN_RESP}" || continue
      out ""
      out ""
      ok "Approved."
      return 0
    fi
    # Any status but 400 is transport-level — the portal's own rate limiter
    # answers 429 {"error":"rate_limited"}, and a proxy 5xx can carry a
    # token-shaped body — so no terminal verdict lives there.
    [ "${status}" = "400" ] || continue
    error=$(json_string_field "${TOKEN_RESP}" error) || error=""
    case "${error}" in
      # Poll on while approval is pending — and on bodies carrying no OAuth
      # error code: parse failures land here as "", and a value outside the
      # token charset is a malformed response, not a code.
      authorization_pending | '' | *[!a-zA-Z0-9._-]*) : ;;
      access_denied)
        warn "the request was denied in the portal — no clients configured"
        return 1
        ;;
      expired_token)
        warn "approval code expired — re-run the installer to try again"
        return 1
        ;;
      invalid_grant)
        warn "the approval code is no longer valid — re-run the installer to try again"
        return 1
        ;;
      *)
        # Any other error code is terminal (RFC 8628: only authorization_pending
        # retries here); retrying it would just spin until the grant expires.
        warn "the portal reported ${error:0:40} — re-run the installer to try again"
        return 1
        ;;
    esac
  done
}

configure_llm_clients() {
  local user_home="$1" ids="" label client_id kind config_file state key
  CONFIGURED_CLIENTS=""
  CLIENTS_FOUND=0
  SCANNED=""
  CONSENTED=""
  [ "${ASSUME_YES}" = "1" ] && return 0
  tty_available || return 0
  clients_phase_ran=1
  # Overridable so the behavior harness can point these at its own sandbox — but
  # only WITHIN this run's temp dir. Taken from the environment unconditionally,
  # an inherited DEVICE_RESP redirected a root-run `curl -o` at any path on the
  # host; sudo's env_reset normally strips it, which is not a guarantee to rest a
  # root write on.
  case "${DEVICE_RESP:-}" in
    "${tmp}"/*) ;;
    *) DEVICE_RESP="${tmp}/device-authorization.json" ;;
  esac
  case "${TOKEN_RESP:-}" in
    "${tmp}"/*) ;;
    *) TOKEN_RESP="${tmp}/device-token.json" ;;
  esac

  scan_llm_clients "${user_home}"

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
    if ! safe_config_value "${key}"; then
      warn "${label}: the delivered key is not a value we will write to a config file"
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

configure_llm_clients "${user_home}" || \
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
dim "  curl --proto '=https' --proto-redir '=https' --globoff -fsSL https://emisar.dev/install-mcp.sh | sudo bash -s -- --uninstall"

---
name: connect-llm
description: Connect an LLM or MCP client to Emisar and certify the connection end to end. Use for installing the emisar-mcp stdio bridge, registering a local client (Claude Code, Cursor, Zed, Copilot CLI, and other stdio clients), wiring a cloud connector (Claude.ai, ChatGPT), repairing a broken client registration, or proving that discovery, action execution, and audit work through the configured client. For installing the on-host runner itself, use the install-emisar skill.
---

# Connect an LLM client to Emisar

Execute this workflow on the machine that runs the customer's MCP client. Do
not require an Emisar source checkout, fork, build toolchain, repository
instructions, or internal contributor skill. Use the public installer,
the signed-in Emisar portal, the installed CLIs, and public documentation.

This skill connects a client to an existing Emisar account. It assumes at
least one runner is already connected (the `install-emisar` skill covers
that); a connected client with zero reachable runners can still be registered,
but the functional checks will be `SKIPPED` and the connection is not
certified end to end.

## Use current public interfaces

Default to the hosted control plane at `https://emisar.dev`. Use a different
`EMISAR_URL` only when the operator identifies and trusts that deployment.

Verify commands before running them:

- Download `${EMISAR_URL%/}/install-mcp.sh` and run its local copy with
  `--help`; follow the installed help, not remembered flags.
- Before a local bridge install, require GitHub CLI and confirm `gh attestation
  verify --help` advertises `--bundle`. Install or update GitHub CLI through the
  workstation's supported package method when it does not. Do not use the
  checksum-only break glass as a substitute.
- After installation, use `emisar-mcp --help` as the installed-version
  contract.
- Use the signed-in **Agents** page for current client configuration and the
  cloud-connector name and URL.
- Use `https://emisar.dev/docs/connect-claude-ai` or
  `https://emisar.dev/docs/connect-chatgpt` for a cloud connector,
  `https://emisar.dev/docs/connect-cli-agent` for a local or CLI client, and
  `https://emisar.dev/docs/mcp-reference` when more detail is needed.
- For an official local bridge install, require outbound HTTPS to
  `tuf-repo-cdn.sigstore.dev:443` and `tuf-repo.github.com:443` so GitHub CLI
  can load the public release-verification trust roots.
- When a registered client lists no tools or a call fails,
  `https://emisar.dev/docs/troubleshooting` owns the client and bridge symptoms.

If installed help differs from public documentation, preserve the machine,
report the exact version skew, and follow the installed artifact's contract
unless this is an explicit upgrade.

## Safety rules

- Treat `emk-` API keys, OAuth tokens, and browser-approval links as secrets.
  Never print, commit, report, or place their literal values in shell history.
  Sanitize captured output.
- Use HTTPS for installer downloads. Plain HTTP is limited to loopback,
  `localhost`, and literal private addresses and must pass the validation below.
  Do not build from source, hand-write another installer, or use an untrusted
  mirror.
- Prefer a pinned `mcp-vX.Y.Z` tag for repeatable automation; verify the tag
  exists. For an interactive latest install, report the exact installed
  version.
- Inventory an existing bridge and client config before changing either.
  Preserve unrelated MCP servers, comments, and formatting in client config
  files; back up operator-owned config before editing it.
- Do not reuse a production `emk-` key in a throwaway probe. Test through the
  persistent configured client and its normal credential store.
- Do not add client-maintained action allowlists or copy another client's
  config shape; the server owns the MCP catalog and runner scope.
- Never claim a skipped or unsupported check is healthy, and never bypass a
  policy denial with SSH, copied shell commands, or a wider credential.

## 1. Discover the client

Establish, asking only for what cannot be discovered safely:

- Which client the operator uses. Cloud clients (Claude.ai, ChatGPT) use the
  remote MCP connector over OAuth and need no local bridge. Local and IDE
  clients (Claude Code, Claude Desktop, Cursor, VS Code, Windsurf, Zed,
  OpenClaw, OpenCode, Pi, Copilot CLI, Gemini CLI, Codex CLI, Goose, Hermes,
  Grok CLI)
  use the `emisar-mcp` stdio bridge.
- Whether `emisar-mcp` is already installed (`command -v emisar-mcp`,
  `emisar-mcp --version`) and where the client keeps its config.
- The control-plane origin (`EMISAR_URL`) and whether the operator can open a
  browser to approve the connection — the installer's default flow mints
  per-client keys through a browser approval, so no key is copied by hand.
- Whether the target runner fleet requires signed dispatch (that changes the
  functional expectations below).

## 2. Cloud client: wire the connector

For Claude.ai or ChatGPT, there is nothing to install. From the signed-in
**Agents** page, take the connector name and the remote MCP server URL, add
the connector in the client's own settings, and complete the OAuth consent —
choosing the intended account on the consent screen. Then continue at step 4.

## 3. Local client: install the bridge and register

Download first so failures are unambiguous and `--help` can be inspected:

```sh
export EMISAR_URL="${EMISAR_URL:-https://emisar.dev}"
EMISAR_URL="${EMISAR_URL%/}"
case "$EMISAR_URL" in
  https://*) ;;
  http://*)
    command -v python3 >/dev/null 2>&1 || {
      echo "python3 is required to validate a private HTTP installer origin" >&2
      exit 1
    }
    EMISAR_URL="$EMISAR_URL" python3 - <<'PY' || exit 1
import ipaddress, os, sys
from urllib.parse import urlsplit

try:
    origin = urlsplit(os.environ["EMISAR_URL"])
    port = origin.port
except ValueError:
    sys.exit("Refusing an invalid HTTP installer origin")
host = (origin.hostname or "").lower()
plain_origin = (origin.scheme == "http" and origin.username is None and
                origin.password is None and origin.path == "" and
                origin.query == "" and origin.fragment == "" and
                (port is None or 1 <= port <= 65535))
host_chars = set("abcdefghijklmnopqrstuvwxyz0123456789.-")
edge_chars = set("abcdefghijklmnopqrstuvwxyz0123456789")
hostname = (bool(host) and host[:1] in edge_chars and
            host[-1:] in edge_chars and set(host) <= host_chars)
allowed = plain_origin and hostname and (host == "localhost" or host.endswith(".localhost"))
try:
    address = ipaddress.ip_address(host)
    canonical = str(address) == host
    networks = ("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12",
                "192.168.0.0/16", "::1/128", "fc00::/7")
    allowed = allowed or (plain_origin and canonical and
                          any(address in ipaddress.ip_network(net) for net in networks))
except ValueError:
    pass
if not allowed:
    sys.exit("Refusing a non-private HTTP installer origin; use HTTPS")
PY
    ;;
  *) echo "Refusing an installer origin that is not HTTP or HTTPS" >&2; exit 1 ;;
esac
installer="$(mktemp)"
trap 'rm -f "$installer"' EXIT HUP INT TERM
command -v gh >/dev/null 2>&1 || {
  echo "GitHub CLI is required to authenticate the release checksum" >&2
  exit 1
}
gh attestation verify --help 2>&1 | grep -q -- '--bundle' || {
  echo "GitHub CLI must support attestation bundle verification" >&2
  exit 1
}
curl -fsSL "$EMISAR_URL/install-mcp.sh" -o "$installer"
bash "$installer" --help
sudo EMISAR_URL="$EMISAR_URL" bash "$installer"
rm -f "$installer"
trap - EXIT HUP INT TERM
```

The installer takes no client argument. It detects the clients already present
on the machine, asks about each one, then mints that client's key through a
browser approval and writes it into that client's own config — so run it where
it can prompt, and let it finish the registration.

After the per-client questions it asks once whether to silence that client's own
"allow this tool?" prompt for the emisar server. It offers this only for the
clients whose setting can name emisar alone (Claude Code, Gemini CLI, Codex CLI,
Grok CLI) and never touches a global approval setting. Answering no changes
nothing, and either answer leaves Emisar policy and approvals in force. This
edits a security setting in a file the operator owns, so answer it from their
instruction — do not enable it on their behalf, and report which clients were
changed.

Adapt only with flags present in the downloaded installer's help. Drop `sudo`
and add `--install-dir "$HOME/.local/bin"` to install without root; pin a
release with `--version mcp-vX.Y.Z`. There is no unattended path to a
registered client: `--yes` skips every prompt, the client step included, so it
installs the bridge binary and registers nothing. `EMISAR_URL` has to reach the
installer's own environment either way — it is written into every client config
it touches.

Keep the client's `emisar/credentials` directory durable and owner-only so key
rotation survives restarts; containerized clients must persist `/config`.

When a browser is genuinely unavailable, or the installer ran without its
prompts, fall back to the **Agents** page's manual per-client snippet, keeping
the key out of shell history and command arguments.

Restart or reload the actual client afterward.

## 4. Verify through the client

Test through the configured client itself, never a synthetic harness:

1. Confirm `tools/list` matches the fixed catalog in
   `https://emisar.dev/docs/mcp-reference`.
2. Call `list_runners` with issues included. Require the intended runner to be
   `connected` with no unexplained issues.
3. Call `list_packs` with `include: "all"` and require the intended packs
   to be present and executable without descriptor or deployment issues. An
   absent expected ref is not diagnosable through MCP; an operator reviews its
   trust and retirement state on the portal's **Packs** page.
4. Call `find_actions` for a low-risk host check, then `get_action` for the
   exact action, pack ref, schema, and runner ref. Prefer a pack's
   `setup.verify` action.
5. Call `run_action` with those exact values and a clear onboarding reason.
   Follow `wait_for_run` through approval or delivery to a terminal state.
   Never auto-approve or widen policy. A denial proves enforcement but fails
   the onboarding functional check.
6. Use `recent_runs` to prove the run belongs to this client and account.

## 5. Verify every health plane

| Plane | Required evidence |
| --- | --- |
| Client | Client name, kind (cloud or stdio), config path or connector location |
| Bridge artifact | Absolute path and exact `emisar-mcp --version` (stdio clients only) |
| Registration | Durable credentials location, key present without its value |
| Tool catalog | `tools/list` matches the documented fixed catalog |
| Fleet state | `list_runners`: intended runner connected, issue list empty or explained |
| Pack visibility | `list_packs include=all`: intended trusted refs present, executable, no issues |
| Functional action | Low-risk verify run reaches terminal success through this client |
| Audit | `recent_runs` contains the same run, attributed to this client |
| Signed dispatch | When configured: this client's signed call succeeds; an unsigned dispatch is rejected |

Repair concrete failures, then rerun the affected row and every downstream
row. Stop only when required checks pass or an external owner must supply a
credential, approval, or runner.

## Report

Use only these states: `PASS`, `DEGRADED`, `FAIL`, `SKIPPED` (name the missing
prerequisite and owner), `UNSUPPORTED`.

```text
Emisar client connection health - <client> - <UTC timestamp>
Overall: PASS | DEGRADED | FAIL | NOT CERTIFIED

Plane              State       Evidence
client             PASS        ...
bridge artifact    PASS        ...
...

Installed: emisar-mcp <version> (or cloud connector)
Functional proof: <action, runner_ref, run_id, terminal status>
Remediated: <what changed and why, or none>
Open items: <owner + exact next action, or none>
```

Overall is `PASS` only when every applicable required row passes. A required
`FAIL` makes it `FAIL`; a required `SKIPPED` or `UNSUPPORTED` makes it `NOT
CERTIFIED`. Include exact versions, paths, endpoint origins, refs, run IDs,
timestamps, and sanitized errors — never credential values or raw logs that
may contain secrets.

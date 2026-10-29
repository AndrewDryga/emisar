# Repeat the Caddy approval test

Tested on 29 October 2026 with real Caddy 2.11.4, a Linux arm64 runner in Docker on macOS, and a local development Portal. The runner/bridge source commit, binary hashes, observed Portal version, pack references, policy, calls, warnings and host journal are in [evidence.json](evidence.json). These are scripted MCP bridge calls. The HTTP service returns synthetic text only.

## Prerequisites

Use a disposable Linux host or container with Caddy installed, an online emisar runner, and the linux-core/caddy packs. Connect emisar-mcp to that same workspace through the normal authentication flow. Follow the [quickstart](https://emisar.dev/docs/quickstart). Keep the runner configuration/state separate from service files. Our restricted test runner admitted only linux.uptime and caddy.reload_config.

Use the default policy: low/medium allow, high require_approval, critical deny, one reviewer, self-approval allowed. We chose single-use approvals, without a standing grant.

## 1. Prepare two service configurations

Create /opt/caddy-demo/before.Caddyfile:

```caddyfile
{
  admin localhost:2019
  auto_https off
}
:8080 {
  respond "before approval"
}
```

Copy it to /opt/caddy-demo/Caddyfile and change only its response to `after approval`. Keep the admin endpoint on localhost. Do not use a production configuration or port.

Start Caddy with the initial file in a separate terminal:

```sh
caddy run --config /opt/caddy-demo/before.Caddyfile --adapter caddyfile
```

Caddy stays running. Confirm the initial response:

```sh
curl -fsS http://127.0.0.1:8080
# before approval
```

For our container, Docker exposed this listener on an assigned loopback host port. Independent checks used that host port; the action ran inside the container.

## 2. Discover exact references and run uptime

```sh
emisar-mcp list_runners --json
emisar-mcp list_packs --json
```

Copy the runner_ref of your connected test host and its exact linux-core/caddy pack_ref. The IDs in evidence.json belong to our disposable fixture; use your own returned values.

Inspect linux.uptime with get_action, then call run_action. Both commands accept a JSON object on stdin with `- --json`. The tool inputs below use YOUR_RETURNED_* placeholders deliberately: replace them with values from discovery.

```json
{
  "action_id": "linux.uptime",
  "pack_ref": "YOUR_RETURNED_LINUX_CORE_PACK_REF",
  "runner_refs": ["YOUR_RETURNED_RUNNER_REF"]
}
```

Pass that object to `emisar-mcp get_action - --json`. For `emisar-mcp run_action - --json`, add `"args": {}`, `"reason": "Read uptime on the disposable service host."` and `"wait": "5s"`. Our response was success with exit code 0 with host uptime. In our Docker container on macOS, uptime describes the Docker VM's kernel.

## 3. Request and approve a reload

Inspect caddy.reload_config with its returned caddy pack_ref and the same runner_ref. Then call run_action with:

```json
{
  "action_id": "caddy.reload_config",
  "pack_ref": "YOUR_RETURNED_CADDY_PACK_REF",
  "runner_refs": ["YOUR_RETURNED_RUNNER_REF"],
  "args": {"file": "/opt/caddy-demo/Caddyfile"},
  "reason": "Reload the disposable Caddy service so its test HTTP response changes to after approval.",
  "wait": "0"
}
```

A pending_approval response includes the actual review URL and a wait_for_run continuation. Fetch the HTTP URL again before approving: it should still say before approval.

In the console, review the command/target/arguments and approve once. Follow the returned wait_for_run continuation; do not resubmit run_action to poll. If a cursor expires, wait_for_run accepts the existing run_id without a cursor.

Require both a successful runner result and an independent HTTP response of after approval. Our successful command returned exit code 0 and printed configuration-environment and file-format warnings; the complete output is preserved in evidence.json.

## The failed first attempt

Our original fixture kept runner configuration and a Caddyfile together under /srv. An operator approved `caddy reload --config /srv/Caddyfile`, but the runner refused it before execution:

```text
argument file: path /srv/Caddyfile is inside the runner's own configuration or state
```

The run was validation_failed and the HTTP body did not change. We moved only the synthetic service file to /opt/caddy-demo/Caddyfile, validated it with Caddy, and obtained a separate approval. No runner protection or policy was weakened.

## Cleanup and limits

Stop only the test Caddy service/container and revoke its disposable credentials when finished. Keep the failed request alongside the successful one. We did not test standing-grant reuse/revocation, policy denial, model behavior, persistent connections or production reliability in this sequence. Caddy's actual HTTP change is checked separately from the approval and runner result.

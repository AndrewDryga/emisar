# Wire protocol

The runner and the control plane talk over a single TLS websocket. The
runner dials out; the control plane never connects to the runner. All
messages are JSON envelopes. Every envelope carries `type`, `protocol_version`,
and (for action-correlated messages) `request_id`.

Protocol version: **1**.

Unknown message types are silently ignored so an old runner can tolerate
a newer cloud that learned new messages. Unknown fields inside a known
message type are also tolerated.

## Connection lifecycle

```
runner --(TLS connect, present auth key)--> cloud
runner --(runner_state)--> cloud
cloud --(run_action #1)--> runner
runner --(action_progress, action_progress, ...)--> cloud
runner --(action_result #1)--> cloud
cloud --(ack_result #1)--> runner
runner --(heartbeat every 30s)--> cloud
...
```

On disconnect: the runner backs off (exponential, capped at
`cloud.reconnect_max`), reconnects, and re-sends `runner_state`.
Liveness is symmetric — the control plane closes a socket that goes
~90s without a heartbeat, so a half-dead TCP session can't hold a
runner "online" forever.

## Auth

The runner's bootstrap auth key (a long-lived bearer secret, dropped
into the VM via image metadata or cloud-init) is exchanged for a
per-runner token via `POST {url}/runner/register` the first time the
runner connects (or whenever no token is persisted). The token is
written to `cloud.token_path` with mode `0600`; every websocket upgrade
to `/runner/socket/websocket` then presents that token as a bearer
credential. Revoke = mark the auth key or token invalid cloud-side; the
next `/runner/register` or upgrade gets a `401` and the runner exits.

There is no HMAC layer on top of TLS — TLS is the trust boundary.

## Messages

### `runner_state` (runner -> cloud)

Sent on every connect and on `SIGHUP` (pack reload).

```json
{
  "type": "runner_state",
  "protocol_version": 1,
  "runner_id": "agt_01HZP3X9...",
  "version": "0.2.0",
  "hostname": "ip-10-0-1-23",
  "group": "cassandra-us-east1",
  "labels": {"region": "us-east-1", "role": "cassandra"},
  "enforce_signatures": true,
  "signing_ca_ids": ["ca-1a2b3c4d"],
  "max_attestation_age_seconds": 86400,
  "packs": {
    "linux-core": {"version": "0.2.0", "hash": "sha256:9b1d..."},
    "cassandra":  {"version": "0.2.0", "hash": "sha256:5c7e..."}
  },
  "actions": [
    {
      "id": "linux.uptime",
      "pack_id": "linux-core",
      "title": "System uptime and load average",
      "kind": "exec",
      "risk": "low",
      "description": "Reports system uptime and 1/5/15-minute load averages...",
      "side_effects": ["Reads /proc/loadavg and /proc/uptime via the uptime utility."],
      "args": [],
      "limits": {"default_timeout": "5s"},
      "output": {"parser": "text", "max_stdout_bytes": 2048, "max_stderr_bytes": 2048}
    }
  ]
}
```

Cloud treats the runner as ground truth for that runner's schemas.
Actions blocked by the runner's local `admission:` allow/deny list are
excluded here — the cloud never even sees them advertised.

`enforce_signatures` (omitted when off) advertises that this runner verifies
a client signature on every dispatch and refuses unsigned ones; the cloud
responds by disabling its own (operator/runbook/API) dispatch to this runner.
When enforcing, the runner also advertises `signing_ca_ids` (the certificate-
authority ids it trusts — the public-key bytes never leave the host) and
`max_attestation_age_seconds` (its freshness window), so the cloud can show the
trusted CAs and warn before a stale-by-approval dispatch. See
[`docs/signed-dispatch.md`](signed-dispatch.md).

### `run_action` (cloud -> runner)

```json
{
  "type": "run_action",
  "protocol_version": 1,
  "request_id": "req_01HZP4...",
  "action_id": "cassandra.nodetool_status",
  "args": {"host": "127.0.0.1"},
  "opts": {"timeout": "60s"},
  "reason": "Pre-repair health check requested by alice@example.com",
  "expected_pack_hash": "sha256:5c7e...",
  "attestation": {
    "version": "emisar-attestation-v2",
    "sig": "b47006e2...",
    "nonce": "a1b2c3...",
    "issued_at": "2026-06-17T12:00:00Z",
    "targets": ["019f5a2e-..."],
    "cert": {
      "ca_id": "ca-prod-2026",
      "key_id": "op-alice",
      "public_key": "79b5562e...",
      "valid_from": "2026-06-17T00:00:00Z",
      "valid_until": "2026-06-18T00:00:00Z",
      "scope": {"group": "prod"},
      "serial": "01J0CERT...",
      "sig": "9e69c413..."
    }
  }
}
```

`attestation` (optional) is the bounded v2 client envelope relayed from the
originating MCP call. Its signature binds the action id, exact JSON arguments,
sorted durable runner-id set, nonce, and timestamp. The cloud can neither forge
nor alter those facts; it is absent on portal-originated dispatch
(operator/runbook/API), which a signature-enforcing runner refuses. See
[`docs/signed-dispatch.md`](signed-dispatch.md).

`opts` fields are clamped to the action's declared min/max envelope.
Any field the action didn't declare a `*_min`/`*_max` for cannot be
overridden — the default wins.

`expected_pack_hash` is the trust pin: the cloud sends the pack hash an
operator last trusted, and the runner re-hashes the on-disk pack before
executing. On mismatch (pack swapped after trust) nothing executes —
the runner replies with a `pack_hash_mismatch` result and re-sends a
fresh `runner_state` so the cloud sees the new reality.

### `action_progress` (runner -> cloud)

Sent zero or more times per `request_id`, while the process runs. One
complete line of output per message; `seq` increases monotonically per
`request_id`.

```json
{
  "type": "action_progress",
  "protocol_version": 1,
  "request_id": "req_01HZP4...",
  "seq": 7,
  "stream": "stdout",
  "chunk": "Datacenter: us-east-1\n"
}
```

The chunk has already been redacted by the runner.

### `action_result` (runner -> cloud)

Sent exactly once per `request_id`, after the process exits or the call
fails. Stdout/stderr content is **not** repeated — cloud already has the
chunks via `action_progress`. SHA-256s + byte counts let cloud verify
nothing was lost mid-stream.

```json
{
  "type": "action_result",
  "protocol_version": 1,
  "request_id": "req_01HZP4...",
  "status": "success",
  "exit_code": 0,
  "duration_ms": 1337,
  "timed_out": false,
  "stdout_sha256": "...",
  "stderr_sha256": "...",
  "stdout_bytes": 412,
  "stderr_bytes": 0,
  "truncated_stdout": false,
  "truncated_stderr": false,
  "redactions": [{"name": "bearer-token", "type": "regex", "count": 0}],
  "reason": "Pre-repair health check requested by alice@example.com",
  "executed_command": "nodetool status",
  "event_id": "evt_01HZP4..."
}
```

`executed_command` is the shell-quoted argv with sensitive args already
masked; `error` (omitted above) carries the failure detail when status
isn't `success`.

Possible `status` values: `success`, `failed`, `error`,
`validation_failed`, `unknown_action`, `pack_hash_mismatch`,
`signature_invalid` (an enforcing runner refused a missing/bad/stale/replayed
signature — the terse cause is in `reason`, a human sentence in `error`).

### `cancel` (cloud -> runner)

Asks the runner to terminate a running action. The runner SIGTERMs,
then SIGKILL after a grace window; an `action_result` with
`status: "failed"` and a `cancelled` reason still goes out.

```json
{
  "type": "cancel",
  "protocol_version": 1,
  "request_id": "req_01HZP4..."
}
```

### `ack_result` (cloud -> runner)

Confirms receipt of an `action_result`. The JSONL log itself is
append-only, so the ack is recorded in the cursor sidecar file
(`events.jsonl.cursor`), marking that event as delivered. No
`action_result` data is re-shipped after an ack.

```json
{
  "type": "ack_result",
  "protocol_version": 1,
  "request_id": "req_01HZP4..."
}
```

### `heartbeat` (runner -> cloud)

Sent every `cloud.heartbeat_every` (default 30s). `action_load` is the
count of in-flight actions on this runner.

```json
{
  "type": "heartbeat",
  "protocol_version": 1,
  "time": "2026-05-19T22:30:00Z",
  "action_load": 0
}
```

### `error` (runner -> cloud)

Non-fatal runner-side error. Does not abort the session.

```json
{
  "type": "error",
  "protocol_version": 1,
  "request_id": "req_01HZP4...",
  "code": "engine_error",
  "message": "..."
}
```

## Reconnect semantics

- Backoff is exponential between `cloud.reconnect_min` and
  `cloud.reconnect_max`.
- On reconnect, the runner always sends `runner_state` first.
- In-flight actions keep executing across the gap; their results go out
  on the new connection. The cloud correlates a result to its run row by
  `(runner_id, request_id)` in the database, so delivery survives the
  socket process dying — the cloud does NOT re-issue `run_action`.
- If the runner stays offline past the dispatch grace window (~2
  minutes), a cloud-side sweep marks its non-terminal runs as errored
  with an explanatory message; a result arriving later for a run that
  no longer matches is acked and dropped.

## Idempotency

`request_id` is the correlation key, and idempotency is layered
cloud-side rather than on the runner:

- An MCP client retry carries the same `Idempotency-Key`, which maps to
  the existing run row — only one `run_action` is ever dispatched per
  logical request, so the runner never has to dedupe inbound work.
- Duplicate `action_result` deliveries (e.g. an ack lost in a reconnect)
  are detected by the cloud — a result for an already-finalized
  `request_id` is re-acked without being re-applied, and a result for a
  `request_id` that matches no run row is logged and dropped.

## Cancellation race

If `cancel` arrives after the action already completed, it's a no-op.
If it arrives mid-execution, the executor cancels the `exec.Cmd`
context. Cloud should treat "I sent cancel and then got a `success`
result" as "the action finished before cancel landed" — not as a bug.

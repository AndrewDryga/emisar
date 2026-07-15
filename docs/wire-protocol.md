# Runner wire protocol

The runner and portal communicate over one TLS websocket initiated by the
runner. The portal never opens a connection to a runner. Every message is a JSON
object with `type` and `protocol_version`; action-correlated messages also carry
`request_id`.

Protocol version: **1**.

Unknown message types and unknown fields inside known messages are tolerated so
additive changes do not break an older peer. Every known message requires the
exact supported protocol version; a missing or different version closes the
session before the message is handled. Security-sensitive known fields use their
exact lowercase JSON names; case aliases are rejected.

## Trust boundaries

- TLS plus the persisted runner bearer token authenticate the websocket. There
  is no HMAC or signed session layer on top of TLS.
- The portal is authoritative for account scope, policy, approval, and audit.
- When signed dispatch is enforced, the customer CA is authoritative for the
  exact `run_action` execution intent. The portal relays that attestation but
  cannot forge or alter one that an honest runner will accept.
- Runner state, progress, and results are authenticated hop by hop by the TLS
  connection. End-to-end runner result signing is deferred.

## Connection lifecycle

```text
runner --(TLS connect with bearer token)--> portal
runner --(runner_state)-------------------> portal
portal --(run_action)---------------------> runner
runner --(action_progress...)------------> portal
runner --(action_result)-----------------> portal
portal --(ack_result)---------------------> runner
runner --(heartbeat...)------------------> portal
```

The bootstrap auth key is exchanged through `POST /runner/register` for a
per-runner token, which is persisted owner-only. Every websocket upgrade then
uses that bearer token. Revoking the key or token makes the next registration or
upgrade fail.

The runner generates and durably stores its UUID `external_id` before its first
registration. `POST /runner/register` requires that nonblank, at-most-255-character
value and returns `400 {"error":"invalid_external_id"}` without consuming the
enrollment key when it is missing or invalid. Reconnects present the same value.
MCP runner references derive their generation suffix as the first 32 lowercase
hex characters of `sha256(external_id)`; the full external ID is never exposed
to MCP.

On disconnect the runner reconnects with bounded exponential backoff and sends a
fresh `runner_state`. In-flight actions continue and queue progress/results for
the next connection. Heartbeats let the portal expire half-open sockets.

## `runner_state`

Sent after every connection and pack reload. The complete encoded frame must not
exceed 2 MiB (2,097,152 bytes); runners validate that before sending. The
message contains the runner version, hostname, group, labels, complete
pack/action advertisement, signature-enforcement state, trusted CA IDs, and
maximum attestation age.

```json
{
  "type": "runner_state",
  "protocol_version": 1,
  "version": "0.2.0",
  "hostname": "dbcas103",
  "group": "cassandra",
  "labels": {"datacenter": "dc1", "rack": "rack3"},
  "enforce_signatures": true,
  "signing_ca_ids": ["ca-prod-2026"],
  "max_attestation_age_seconds": 86400,
  "packs": {
    "cassandra": {
      "version": "1.4.0",
      "hash": "sha256:7a65c099fe1d3c8d2b250d211d4792ec1e3919b87f49ffb998ee6e4366b4b6fe"
    }
  },
  "actions": [
    {
      "id": "cassandra.nodetool_status",
      "pack_id": "cassandra",
      "title": "Cassandra ring status",
      "summary": "Reports node state and ownership for the Cassandra ring.",
      "kind": "exec",
      "risk": "low",
      "description": "Runs nodetool status and returns the bounded result.",
      "side_effects": [],
      "args": [],
      "limits": {"default_timeout": "60s"},
      "output": {"parser": "text", "max_stdout_bytes": 16384, "max_stderr_bytes": 16384}
    }
  ]
}
```

Runner advertisements prove deployment only. MCP model-facing descriptors come
from the operator-trusted manifest for the exact pack hash. A mismatch excludes
that runner/action from execution.

## `run_action`

```json
{
  "type": "run_action",
  "protocol_version": 1,
  "request_id": "req_01HZP4...",
  "operation_id": "op_724NN9NMDZ1T76NARWCKM5A0D6",
  "action_id": "cassandra.nodetool_status",
  "pack_ref": "cassandra@1.4.0/sha256:7a65c099fe1d3c8d2b250d211d4792ec1e3919b87f49ffb998ee6e4366b4b6fe",
  "args": {"host": 9007199254740993},
  "reason": "Confirm ring health before rerolling the canary.",
  "attestation": {
    "version": "emisar-attestation-v4",
    "tool": "run_action",
    "portal_origin": "https://emisar.dev",
    "action_id": "cassandra.nodetool_status",
    "pack_ref": "cassandra@1.4.0/sha256:7a65c099fe1d3c8d2b250d211d4792ec1e3919b87f49ffb998ee6e4366b4b6fe",
    "args_sha256": "...",
    "runner_refs": ["cassandra-dbcas103~8e9a70d2d45a1f23c8b4ae63da1384f1"],
    "reason": "Confirm ring health before rerolling the canary.",
    "operation_id": "op_724NN9NMDZ1T76NARWCKM5A0D6",
    "nonce": "0123456789abcdef0123456789abcdef",
    "issued_at": "2026-07-14T12:00:00Z",
    "sig": "...",
    "cert": {"ca_id": "ca-prod-2026", "key_id": "op-alice", "public_key": "...", "valid_from": "2026-07-14T00:00:00Z", "valid_until": "2026-07-15T00:00:00Z", "scope": {"group": "cassandra", "labels": {}}, "serial": "01J0CERT...", "sig": "..."}
  }
}
```

### Exact arguments

The portal relays the exact UTF-8 JSON value bytes from the MCP
`run_action.args` object. It does not reconstruct them from JSONB. The runner
rejects missing/non-object arguments, duplicate keys at any depth, case aliases
of known fields, invalid UTF-8, unpaired surrogates, more than 64 levels of JSON
nesting, arguments over 32 KiB, and a complete message over 128 KiB. It decodes
numbers with `UseNumber`; values above 2^53 are never converted through
`float64`.

### Signed action attestation v4

The bridge sends `Emisar-Attestation` as unpadded base64url of the bounded JSON
envelope. The portal accepts at most 8192 encoded header bytes, compares its
fields with the authenticated request, and relays the decoded envelope unchanged.
The Ed25519 signature covers fixed JSON binding:

- literal version and tool name;
- canonical portal origin;
- exact action ID and immutable `pack_ref`;
- SHA-256 of the exact argument bytes;
- canonical sorted complete `runner_refs`;
- exact reason;
- operation ID, nonce, and RFC3339 issuance time.

An enforcing runner verifies the leaf certificate against its configured
customer CA, certificate validity and local group/label scope, origin,
freshness, durable nonce replay, exact local pack bytes and action membership,
argument digest, all delivery fields, and its own external-ID-derived target
suffix immediately before execution. Pack verification and execution use the
same immutable registry snapshot, so a concurrent reload cannot swap the action
between the gate and process start.

Unsigned portal/operator/runbook dispatch is accepted only when signature
enforcement is disabled. There is no compatibility mode for earlier attestation
formats.

## Progress and result

`action_progress` carries a monotonically increasing sequence, stream, and one
already-redacted, valid-UTF-8 output chunk. The runner normalizes invalid bytes
after redaction and before progress emission, parsing, audit hashing, or byte
counting, so every downstream representation uses one byte stream.

`action_result` is emitted exactly once after the process exits or the runner
refuses the call. It carries terminal status, exit code, duration, emitted
stream hashes/counts, total and dropped progress-chunk counts, truncation flags,
redaction counts, masked executed command, reason, and local audit event ID.
Output bytes are not repeated in the terminal message. Emitted hashes describe
every normalized, redacted byte admitted by the action's output caps; truncation
flags disclose bytes omitted at those caps. The hashes do not claim that every
emitted chunk reached the portal. The portal accepts unique chunks idempotently,
keeps later chunks even when an earlier one was lost, and persists
`output_complete` only when its accepted count matches the runner's total and
the runner reports no local drops.

Stable result statuses are `success`, `failed`, `error`, `validation_failed`,
`unknown_action`, `pack_hash_mismatch`, and `signature_invalid`.

Results are authenticated by the runner websocket, not end-to-end signed. The
portal must not describe them as CA-verified runner receipts.

## Cancellation and acknowledgement

`cancel` names a `request_id`. If the action is running, the runner terminates it
with the configured grace period and still emits one terminal result. A cancel
that loses the race with completion is a no-op.

`ack_result` confirms durable portal receipt of an `action_result`. The runner
records the acknowledgement in its durable dispatch log so it need not resend
that result after reconnect. A lost acknowledgement can cause a duplicate
result; the portal reapplies neither output nor terminal state.

## Replay and failure behavior

The portal uses one stable `request_id`, `operation_id`, and dispatch digest for
delivery retries. The runner replay store binds that tuple before execution.
An identical duplicate returns the recorded in-progress or terminal state; the
same identifiers with different facts are refused. Replay records and signed
nonces are durable and bounded. Only one runner process may own a replay/nonce
store at a time.

If a host crashes after process start but before a terminal result is durable,
the runner reports `outcome_unknown` after restart and never executes that tuple
again automatically. This is the honest boundary for external side effects.

Malformed or oversized messages, invalid signatures, pack mismatches, replay
conflicts, and admission failures execute nothing and produce bounded errors
without echoing arguments, output, credentials, certificates, or signatures to
logs.

## Limits

| Item | Limit |
| --- | ---: |
| Complete `run_action` message | 128 KiB |
| Exact `args` object | 32 KiB |
| JSON nesting | 64 levels |
| Runner refs in one signed action | 16 |
| `Emisar-Attestation` HTTP header | 8192 encoded bytes |
| Concurrent actions per runner | 8 by default |

The code and fixed vectors in `mcp/internal/attest` and
`runner/internal/attest` are byte-identical and checked from repository CI.

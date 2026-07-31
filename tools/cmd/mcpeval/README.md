# mcpeval — real-client MCP certification

`mcpeval` proves that a real headless client can use the candidate
`emisar-mcp` bridge correctly against an Emisar fixture stack. It supports
Claude Code, Codex CLI, Gemini CLI, and Grok CLI. The scorer reads recorded
tool behavior, not the model's final prose.

The candidate bridge connects only to a loopback relay. That relay alone holds
the real `EMISAR_API_KEY`; the client and bridge receive a short-lived local
credential. Before forwarding a call, the relay rejects tools, actions, packs,
and runners outside the scenario allowlists. It also rejects `run_action`
unless the client first completed `get_action` for the same action and pack.

Positive cases require:

- the expected action in the first five `find_actions` candidates;
- the required tool calls and one action from every required outcome group;
- no wrong action, pack, or runner;
- every started run driven to a terminal result through returned
  continuations; and
- a successful client process.

No-action cases require `find_actions` to return no candidate. Selecting or
dispatching a nearby action fails the case.

All cases also fail on a policy-blocked call, portal `invalid_args` rejection
on a mutation, placeholder dispatch reason, repeated failing call, inspection
continuity violation, timeout, or nonzero client exit. Reports record the
corpus digest, partition, exact client and bridge versions, calls, latency, and
normalized token usage. Release reports omit prompts and client output.

## Development runs

Boot the fixture stack and build the exact bridge under test:

```sh
docker compose up -d --wait portal runner-1 runner-2 runner-3
(cd mcp && go build -o /tmp/emisar-mcp-eval .)

export EMISAR_API_KEY="the seeded development key"
export ANTHROPIC_API_KEY="..."

(cd tools && go run ./cmd/mcpeval \
  -provider claude \
  -bridge-bin /tmp/emisar-mcp-eval \
  -scenario read-only-host-health \
  -out /tmp/mcpeval.json)
```

Set the provider credential expected by the selected client:
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, or `XAI_API_KEY`.
Use `-provider claude|codex|gemini|grok`; `-model` pins a provider model.
Each run uses a fresh temporary project and a stripped environment.

Headless Codex requires `-codex-bypass-sandbox` to dispatch annotation-gated
tools. That option belongs only in an externally isolated environment such as
the certification job or a deliberate local sandbox.

The committed development corpus is
[`tools/mcpeval/scenarios.json`](../../mcpeval/scenarios.json). Validate any
corpus without starting a client:

```sh
(cd tools && go run ./cmd/mcpeval \
  -scenarios ../held-out.json \
  -validate-corpus \
  -require-held-out)
```

## Held-out release corpus

Release qualification uses an uncommitted version 2 corpus created after the
candidate is locked:

```json
{
  "version": 2,
  "kind": "held_out",
  "partition_id": "opaque-partition-id",
  "scenarios": [
    {
      "id": "opaque-positive-id",
      "intent_group": "opaque-intent-family",
      "expected_outcome": "positive",
      "prompt": "held-out operator request",
      "allowed_tools": ["find_actions", "get_action", "run_action", "wait_for_run"],
      "allowed_actions": ["pack.action"],
      "allowed_pack_refs": ["pack@1.2.3/sha256:exact-content-hash"],
      "allowed_runner_refs": ["fixture-runner-1~exact-generation-id"],
      "required_tools": ["find_actions", "get_action", "run_action"],
      "required_actions": [["pack.action"]],
      "required_search_actions": [["pack.action"]]
    },
    {
      "id": "opaque-negative-id",
      "intent_group": "opaque-negative-family",
      "expected_outcome": "no_action",
      "prompt": "held-out request with no Emisar capability",
      "allowed_tools": ["find_actions"],
      "required_tools": ["find_actions"]
    }
  ]
}
```

The real corpus must contain four through eight cases: at least two positive
and two no-action cases, with each outcome split across at least two intent
groups. Every positive case names exact allowed pack and runner refs. The
validator rejects missing evidence, a required value outside its allowlist,
duplicate IDs, unknown fields, unrelated mutation tools, oversized corpora,
and development corpora presented as release evidence.

Store the base64-encoded corpus only as `MCP_EVAL_HELD_OUT_B64` in the protected
`mcp-certification` GitHub environment. Keep provider credentials and the
seeded fixture API key in that environment too. A person who tunes search or
descriptions must not see the active partition. After a held-out failure is
fixed generally, certify against a fresh held-out partition.

## Release qualification workflow

[`mcp-eval.yml`](../../../.github/workflows/mcp-eval.yml) has two modes:

- the weekly/manual development run uses the committed corpus; and
- a manual run with `qualification=true` uses the protected held-out corpus
  and becomes release evidence.

Both modes install pinned client versions, build the candidate bridge from the
workflow commit, boot three fixture runners, and run every case independently
through Claude, Codex, and Gemini. Release qualification also requires an
explicit model ID for every client. Missing credentials or models, a missing
held-out corpus, an invalid corpus, one failed case, or one failed client lane
fails the job. Success requires Claude, Codex, and Gemini to pass the same
corpus. Grok remains available for optional development runs, but is not a
release gate.

The qualification artifact names the candidate commit and includes one JSON
report per client and case. It contains the corpus digest and opaque IDs, but
not held-out prompts or client stdout/stderr.

## Adding development cases

Add a realistic outcome-stated prompt with fail-closed `allowed_*` fields and
the `required_*` evidence needed to prove completion. `required_actions` and
`required_search_actions` are groups of equivalent actions: any one member
satisfies a group. Required entries must be subsets of their allowlists.

Keep committed cases non-destructive unless the fixture stack explicitly owns
and resets the mutation. Never copy an active held-out prompt into the
development corpus.

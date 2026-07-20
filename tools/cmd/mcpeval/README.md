# mcpeval — real-agent MCP conformance eval

`mcpeval` proves that a real, unsteered coding agent can drive the Emisar MCP
API correctly end to end. It starts a loopback HTTP relay in front of a local
portal, runs a headless agent (Claude Code by default, Codex as a best-effort
second lane) against that relay, and scores the recorded API behavior — never
the model's prose — so the signal survives model drift.

The relay is the safety boundary: it alone holds `EMISAR_API_KEY` (the bearer
is injected upstream; the agent process never sees it), accepts only a
random-token loopback endpoint, bounds every frame, and blocks — before the
portal — any tool or action outside the scenario allowlist, plus any
`run_action` that lacks a prior successful `get_action` for the same action
and pack.

Hard failures (exit nonzero): a policy-blocked call, a portal `invalid_args`
rejection on a mutation, an inspection-continuity violation (a `run_action`
with no prior `get_action` for the same action and pack), a placeholder
`run_action` reason (filler like "test" or the bare action id — only the
boolean verdict is recorded, never the reason text, since reports upload as
public CI artifacts), the same failing call repeated more than twice, a
started run not driven to a terminal status via the returned continuations, a
required tool/action that never succeeded, or an agent process that timed out
or exited nonzero. Everything else — including the
final answer captured in the agent's stdout — is reported, not scored.

The optional `run_action` evidence/expected justification chain is reported, not
scored: the summary counts how often the agent supplied each (`evidence_given`,
`expected_given`) as presence booleans only — never the field text, since
reports upload as public CI artifacts.

## Run locally

Boot the dev stack from the repo root, then run the eval against it:

```sh
docker compose up -d --wait portal
docker compose up -d --wait runner-1 runner-2 runner-3

export EMISAR_API_KEY="emk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"  # the seeded dev key
export ANTHROPIC_API_KEY=...  # the driver runs `claude --bare`, which auths only via this key

cd tools && go run ./cmd/mcpeval -provider claude -out /tmp/mcpeval.json
```

`-provider codex` uses the Codex CLI instead (auth via `OPENAI_API_KEY` or an
existing `codex login`; pass `-model` to pin one). Headless Codex cancels
annotation-gated MCP tools ("user cancelled MCP tool call"), so a codex run
that must dispatch also needs `-codex-bypass-sandbox` — it passes
`--dangerously-bypass-approvals-and-sandbox`, which per its own contract
belongs in externally sandboxed environments (the CI job) or a deliberate
local opt-in. Without it a codex run scores discovery conformance only.
`-scenario` selects from
[`tools/mcpeval/scenarios.json`](../../mcpeval/scenarios.json); `-model`,
`-timeout`, and `-budget-usd` pin the run. The agent executes in a throwaway
temp workspace with a stripped environment.

## The scheduled workflow

[`mcp-eval.yml`](../../../.github/workflows/mcp-eval.yml) runs weekly (and on
manual dispatch, with optional `claude_model` / `codex_model` inputs): it boots
the compose stack, waits for three connected fixture runners, then runs BOTH
provider lanes — Claude and Codex — each gated only on its own repo secret
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`). A lane whose secret is absent is
skipped; the job fails if neither is configured, and fails if either lane
violates conformance. Both JSON reports upload as artifacts. Codex is a
first-class scheduled lane, not opt-in — the ChatGPT trace is what motivated
this eval.

## Adding scenarios

Add an entry to `scenarios.json`: a realistic outcome-stated prompt (no
procedural steering), fail-closed `allowed_tools` / `allowed_actions`, and the
`required_tools` / `required_actions` that must succeed for the run to pass.
`required_actions` is a list of GROUPS of equivalent actions — any one member
succeeding satisfies its group (`[["linux.uptime", "debugging.loadavg"], ...]`)
— because the eval scores outcomes, not one recipe: catalog changes
legitimately shift which equivalent an agent picks. Required entries must be
subsets of the allowlists — the loader rejects anything else. Keep scenarios
read-only unless the fixture stack is designed for the mutation.

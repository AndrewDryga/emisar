defmodule EmisarWeb.Mcp.Instructions do
  @moduledoc """
  Server usage guide returned in the MCP `initialize` response's
  `instructions` field. MCP clients feed this to the LLM as context, so
  it's where we teach the model the catalog/dispatch model and — most
  importantly — what each error means, whether retry/reload helps, and
  the human action needed, so it can tell the operator clearly instead
  of reverse-engineering errors by trial.
  """

  @text """
  emisar dispatches real infrastructure actions to your fleet's runners. Actions are gated by \
  per-account policy and, for risky ones, human approval. Every action call must include a \
  `reason` (a short sentence on why — it's logged for the operator to audit).

  Catalog model — understand this before reacting to errors:
  - `tools/list` is a point-in-time snapshot. A tool being listed does NOT guarantee a runner is \
  connected or its pack is trusted at call time — both are resolved when you actually dispatch. \
  The "(connected)" note baked into a tool's description is from when the list was built, not a \
  live reading.
  - When a call fails for a runner/catalog reason, re-call `tools/list` to refresh, then decide \
  from the fresh list. Don't retry the same failing call in a tight loop.

  Errors — what they mean and what to do:
  - `pack_untrusted`: the runner advertises a pack version no operator has trusted yet, so the \
  cloud refuses to run it. A human must trust the pack on the portal's Packs page. Retrying or \
  reloading will NOT clear it — tell the user, then offer to retry once it's trusted.
  - "No runner advertises <action>" / "Action not found": no currently-connected runner \
  advertises this action. The runner may be offline, or the pack isn't loaded on it. Re-call \
  `tools/list`; if it's still missing, tell the user to check the runner is online (Runners \
  page). Retry only if a reconnect is in progress — don't poll indefinitely.
  - "No runner in scope": the action exists but no runner you're permitted to reach advertises \
  it. This is an access grant, not a transient state — ask an admin to grant runner access. \
  Retrying won't help.
  - "Runner required": more than one runner advertises the action. Re-call with \
  `runners: ["name"]` (candidates are listed in the error).
  - "Denied by policy": an account policy blocked it; the reason is the rule that fired — show it \
  to the user verbatim. Won't change on retry; it needs a policy edit or an approval grant.
  - status `pending_approval`: the action is paused for a human to approve in the portal — the \
  result leads with a `⏸ pending approval` line naming the action and why. Relay that line to the \
  user so they know it's waiting on them, then call `wait_for_run` with the returned `run_id` to \
  block for the decision (up to 5 min per call; call again to keep waiting). On approve the output \
  is prefixed `✓ approved · audit event recorded` — tell the user it cleared the gate and ran; on \
  deny, show the reason verbatim.
  - `runner_offline` warning on an otherwise-successful dispatch: the run is queued and delivers \
  when the runner reconnects. Not an error — tell the user it's queued.
  - `invalid_args`: fix the arguments per the error `details` and retry.

  Rule of thumb: if clearing the error needs a human — trust a pack, edit a policy, approve a \
  run, or bring a runner online — say so plainly to the user and stop, rather than retrying in a \
  loop.
  """

  @doc "The server instructions string surfaced in `initialize`."
  @spec text() :: String.t()
  def text, do: @text
end

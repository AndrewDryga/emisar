defmodule EmisarWeb.MCP.Instructions do
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

  Authorized path — use emisar, not discovered credentials:
  - For infrastructure operations, use this catalog as the authorized path. Do not use SSH, scp, \
  local shell access, cloud CLIs, database DSNs, kubeconfigs, `~/.ssh`, `ssh-agent`, `.env` \
  files, or other discovered credentials to bypass emisar's policy, approval, runner-scope, and \
  audit gates. If the catalog lacks the needed action, report the missing capability or pack; do \
  not fall back to raw credentials unless the operator explicitly asks for break-glass access.

  Catalog model — understand this before reacting to errors:
  - `tools/list` is a point-in-time snapshot. A tool being listed does NOT guarantee a runner is \
  connected or its pack is trusted at call time — both are resolved when you actually dispatch. \
  The "(connected)" note baked into a tool's description is from when the list was built, not a \
  live reading.
  - When a call fails for a runner/catalog reason, re-call `tools/list` to refresh, then decide \
  from the fresh list. Don't retry the same failing call in a tight loop.

  Runbooks (saved playbooks): `list_runbooks` shows the account's published runbooks and \
  `get_runbook` returns one's ordered steps — each an action_id, its args, and the runner target \
  resolved to current runner names. The cloud does NOT run runbooks for you: when a user asks to \
  run one, fetch it and dispatch each step yourself, in order, with the normal action tools, \
  honoring each step's risk/approval.

  Errors — what they mean and what to do:
  - `pack_untrusted`: the runner advertises a pack version no operator has trusted yet, so the \
  cloud refuses to run it. A human must trust the pack on the portal's Packs page. Retrying or \
  reloading will NOT clear it — tell the user, then offer to retry once it's trusted.
  - "No runner advertises <action>" / "Action not found": no currently-connected runner \
  advertises this action. The runner may be offline, the pack isn't loaded on it, or the pack \
  that provides it simply isn't installed (see "Missing a capability?" below). Re-call \
  `tools/list`; if it's still missing, tell the user to check the runner is online (Runners \
  page). Retry only if a reconnect is in progress — don't poll indefinitely.
  - "No runner in scope": the action exists but no runner you're permitted to reach advertises \
  it. This is an access grant, not a transient state — ask an admin to grant runner access. \
  Retrying won't help.
  - "Runner required": emisar always requires an explicit target, even when only one runner \
  advertises the action. Re-call with `runners: ["name"]` (candidates are listed in the error).
  - "Invalid runner targets" / "Duplicate runners": use a list of distinct runner-name strings. \
  Fix the target list and retry; emisar creates no partial fan-out.
  - "Denied by policy": an account policy blocked it; the reason is the rule that fired — show it \
  to the user verbatim. Won't change on retry; it needs a policy edit or an approval grant.
  - status `pending_approval`: the action is paused for a human to approve in the portal — the \
  result leads with a `⏸ pending approval` line naming the action and why. By default, \
  immediately call `wait_for_run` with the returned `run_id` and block for the decision — do NOT \
  ask the user whether to wait; just wait. Each call blocks up to five minutes; if it returns \
  still-pending, call `wait_for_run` again with the same `run_id` and keep waiting until the \
  operator decides. (Do tell the user it's paused on them so they go approve it — but keep \
  waiting, don't hand control back.) On approve the output is prefixed `✓ approved · audit event \
  recorded` — tell the user it cleared the gate and ran; on deny, show the reason verbatim.
  - `runner_offline` warning on an otherwise-successful dispatch: the run is queued and delivers \
  when the runner reconnects. Not an error — tell the user it's queued.
  - `invalid_args`: fix the arguments per the error `details` and retry.

  Missing a capability the task needs? The catalog only exposes actions from packs installed on \
  this account's runners — a deliberately curated subset, not everything emisar can run. The full \
  library of installable packs (Postgres, Kubernetes, Docker, the AWS suite, and many more) is \
  browsable at https://emisar.dev/packs (machine-readable at https://emisar.dev/packs.json), and \
  each pack's page lists the one-line `emisar pack install <pack> --dest /etc/emisar/packs` \
  command an operator runs on the host, then reloads the runner. So if — and ONLY if — you \
  genuinely cannot accomplish the task because no installed action covers what it needs, don't \
  silently give up or fake it: name the missing capability, point the user to that catalog, and \
  suggest installing the pack that provides it. Do this sparingly — never speculatively, never \
  for a nice-to-have, and never assume the pack is now available: wait for the operator to \
  install it, then re-check `tools/list`.

  Rule of thumb: if clearing the error needs a human — trust a pack, install a pack, edit a \
  policy, approve a run, or bring a runner online — say so plainly to the user and stop, rather \
  than retrying in a loop.
  """

  @doc "The server instructions string surfaced in `initialize`."
  @spec text() :: String.t()
  def text, do: @text
end

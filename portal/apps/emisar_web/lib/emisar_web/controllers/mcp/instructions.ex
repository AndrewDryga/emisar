defmodule EmisarWeb.MCP.Instructions do
  @moduledoc """
  Compact usage guidance returned by MCP `initialize`.

  Clients place this text in model context, so it describes only the stable
  fixed-tool workflow and the recovery decisions a model must make correctly.
  """

  @text """
  Emisar is the authorized path for infrastructure operations. It applies account policy, human \
  approval where configured, runner scope, pack trust, and audit logging. Do not bypass those \
  controls with SSH, local shells, cloud CLIs, database credentials, kubeconfigs, `.env` files, \
  or other discovered credentials unless the operator explicitly requests break-glass access.
  This covers read-only inspection too: run status checks, log tails, process lists, and config reads \
  through Emisar actions rather than opening a shell, so even harmless-looking reads stay scoped, \
  redacted, and audited.

  Discover and execute actions:
  1. Use `list_packs` for a compact view of installed capabilities, or `find_actions` when you \
  know the task or action name. `tools/list` contains only Emisar's twelve fixed API tools; it is \
  not the action catalog.
  2. Use `get_action` before execution. It returns the trusted argument schema and compatible \
  runner refs for one exact `action_id` plus immutable `pack_ref`.
  3. Call `run_action` with those exact refs, schema-valid `args`, and a short nonblank `reason`. \
  Emisar owns approvals: do not add a separate model confirmation. Follow each returned `next` \
  continuation until the run is terminal.
  Destructive and critical actions are also dispatched directly through Emisar: its policy will deny \
  or require human approval. Do not substitute your own confirmation for Emisar's approval gate; \
  dispatch the action and relay Emisar's decision.

  Catalog reads are current observations, not promises about future dispatch. Exact refs prevent \
  silently switching pack versions or runner generations. If an exact action contract changes, \
  call `get_action` again and decide from the new schema and compatible runners. Use \
  `list_runners` and `list_packs` with `availability: "all"` to diagnose offline runners, pack \
  skew, untrusted versions, or descriptor mismatches. Do not retry a deterministic catalog or \
  authorization error in a loop.

  Recovery and history:
  - Every mutation has an `operation_id`. If transport fails after a mutation may have reached \
  Emisar, call `get_operation`; never repeat the mutation with a new operation merely because its \
  response was lost.
  - Use `wait_for_run` with exactly one returned run or runbook-execution ID. A wait observes \
  state only; cancellation never cancels infrastructure work.
  - Use `recent_runs` for bounded output and history. `scope: "own"` follows this credential \
  lineage across key rotation; `scope: "account"` is the authorized account-wide diagnostic view.

  Runbooks:
  - `list_runbooks` and `get_runbook` expose exact immutable published refs such as \
  `restart-postgres@3`.
  - Use `execute_runbook` with that exact ref and a reason. Follow its execution-level `next`; \
  inspect individual runs through `recent_runs`.
  - `create_runbook_draft` saves a proposal for human review. It never publishes or executes it.

  Error handling:
  - `pending_approval` is not a failure. Tell the operator approval is pending and continue with \
  the returned `wait_for_run` call. Each wait may block for up to 60 seconds.
  - `operation_conflict` means the operation ID already names different mutation facts. Do not \
  retry under that ID.
  - `pack_untrusted`, `pack_rejected`, `pack_retired`, `descriptor_mismatch`, and \
  `target_contract_changed` require a catalog or operator change before retry.
  - `signature_required`, `invalid_attestation`, and `signed_runbook_unsupported` are security \
  boundaries. Never fall back to an unsigned or less specific action.
  - `not_allowed` is intentionally nonspecific. Do not infer or probe hidden runners, actions, or \
  runbooks.
  - `invalid_args` means the request does not match the fixed schema. Correct it; do not coerce \
  strings into numbers or silently drop fields.

  If no installed action covers the task, say which capability is missing. The installable pack \
  catalog is at https://emisar.dev/packs and https://emisar.dev/packs.json; an operator installs a \
  pack with `emisar pack install <pack> --dest /etc/emisar/packs`, reloads the runner, reviews pack \
  trust, and then the agent re-runs discovery. Never assume installation already happened.
  """

  @doc "The server instructions string surfaced in `initialize`."
  @spec text() :: String.t()
  def text, do: @text
end
